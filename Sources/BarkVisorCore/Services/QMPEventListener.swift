import Foundation
import GRDB

/// Persistent QMP event listener that monitors running VMs for asynchronous events.
///
/// Uses a dedicated QMP socket (separate from the metrics/command socket) to maintain
/// a long-lived connection per VM. Handles events:
/// - SHUTDOWN: VM shutdown (guest-initiated or ACPI powerdown)
/// - GUEST_PANICKED: Kernel panic (process may not exit)
/// - BLOCK_IO_ERROR: Disk I/O failure
/// - DEVICE_TRAY_MOVED: Media ejected
/// - RESET: VM reset
public actor QMPEventListener {
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct Run {
        let generation: UInt64
        let cancel: CancelFlag
        let client: QMPClient
    }

    private struct QMPEventBox: @unchecked Sendable {
        let event: [String: Any]
    }

    private var runs: [String: Run] = [:]
    private var nextGeneration: UInt64 = 0
    private weak var vmManager: VMManager?
    private var stateStreamService: VMStateStreamService?
    private var observation: RuntimeObservation?
    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public func setVMManager(_ manager: VMManager) {
        vmManager = manager
    }

    public func setStateStreamService(_ service: VMStateStreamService) {
        stateStreamService = service
    }

    public func setObservation(_ observation: RuntimeObservation?) {
        self.observation = observation
    }

    // MARK: - Lifecycle

    public func start(vmID: String, eventSocketPath: String) {
        if let previous = runs.removeValue(forKey: vmID) {
            previous.cancel.set()
            previous.client.interrupt()
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        let client = QMPClient(socketPath: eventSocketPath, timeoutSeconds: 3)
        let cancel = CancelFlag()
        let listener = self
        Thread.detachNewThread {
            Self.ioLoop(
                vmID: vmID,
                generation: generation,
                socketPath: eventSocketPath,
                client: client,
                cancel: cancel,
                listener: listener,
            )
        }
        runs[vmID] = Run(generation: generation, cancel: cancel, client: client)
    }

    public func stop(vmID: String) {
        guard let run = runs.removeValue(forKey: vmID) else { return }
        run.cancel.set()
        run.client.interrupt()
    }

    public func stopAll() {
        for (_, run) in runs {
            run.cancel.set()
            run.client.interrupt()
        }
        runs.removeAll()
    }

    private func isCurrent(vmID: String, generation: UInt64) -> Bool {
        runs[vmID]?.generation == generation
    }

    private func commitPanicState(vmID: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE vms SET state = 'error', updatedAt = ? WHERE id = ?",
                arguments: [iso8601.string(from: Date()), vmID],
            )
        }
    }

    private nonisolated static func waitForSocketPath(_ path: String, cancel: CancelFlag) -> Bool {
        var waited: TimeInterval = 0
        while !cancel.isSet {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            if waited >= 2 {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
            waited += 0.01
        }
        return false
    }

    private nonisolated static func ioLoop(
        vmID: String,
        generation: UInt64,
        socketPath: String,
        client: QMPClient,
        cancel: CancelFlag,
        listener: QMPEventListener,
    ) {
        while !cancel.isSet {
            if !waitForSocketPath(socketPath, cancel: cancel) {
                if cancel.isSet { return }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            do {
                try client.connect()
                client.setReceiveTimeoutSeconds(0)
            } catch {
                client.disconnect()
                if cancel.isSet { return }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            while !cancel.isSet {
                guard let message = try? client.readMessagePublic() else { break }
                guard message["event"] != nil else { continue }
                let box = QMPEventBox(event: message)
                Task {
                    await listener.handleEvent(vmID: vmID, generation: generation, event: box.event)
                }
            }
            client.disconnect()
            if cancel.isSet { return }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func forwardObservation(vmID: String, eventType: String) async {
        let kind: QMPObservationKind? = switch eventType {
        case "SHUTDOWN": .shutdown
        case "GUEST_PANICKED": .guestPanicked
        case "RESET": .reset
        default: nil
        }
        if let kind {
            await observation?.applyQMP(workloadID: vmID, event: kind)
        }
    }

    private func handleEvent(vmID: String, generation: UInt64, event: [String: Any]) async {
        guard let eventType = event["event"] as? String else { return }
        guard isCurrent(vmID: vmID, generation: generation) else { return }
        await forwardObservation(vmID: vmID, eventType: eventType)
        let data = event["data"] as? [String: Any]

        switch eventType {
        case "SHUTDOWN":
            let guest = (data?["guest"] as? Bool) ?? false
            let reason = (data?["reason"] as? String) ?? "unknown"
            Log.vm.info("Shutdown detected (guest-initiated: \(guest), reason: \(reason))", vm: vmID)

            // For guest-initiated shutdowns (e.g. `poweroff` inside the VM),
            // tell VMManager to ensure QEMU exits — it can linger on macOS HVF.
            // User-initiated shutdowns (ACPI powerdown) are handled by VMManager.stop().
            if guest {
                guard isCurrent(vmID: vmID, generation: generation) else { return }
                await vmManager?.handleGuestShutdown(vmID: vmID)
            }

        case "GUEST_PANICKED":
            let action = (data?["action"] as? String) ?? "unknown"
            Log.vm.error("Kernel panic detected (action: \(action))", vm: vmID)

            guard isCurrent(vmID: vmID, generation: generation) else { return }
            do {
                try commitPanicState(vmID: vmID)
                let event = VMStateEvent(id: vmID, state: "error", error: "Kernel panic")
                await AuditService.logVMEvent(
                    action: VMLifecycleAction.crashed,
                    vmID: vmID,
                    detail: "{\"reason\":\"kernel panic (\(action))\"}",
                    db: dbPool,
                )
                guard isCurrent(vmID: vmID, generation: generation) else { return }
                await vmManager?.recordHealthError("Kernel panic", for: vmID)
                await stateStreamService?.broadcast(event: event)
            } catch {
                Log.vm.error("Failed to update DB for panicked VM \(vmID): \(error)", vm: vmID)
            }

        case "BLOCK_IO_ERROR":
            let device = (data?["device"] as? String) ?? "unknown"
            let operation = (data?["operation"] as? String) ?? "unknown"
            let action = (data?["action"] as? String) ?? "unknown"
            Log.vm.error("Disk I/O error on \(device): \(operation) (action: \(action))", vm: vmID)
            await AuditService.logVMEvent(
                action: VMLifecycleAction.crashed,
                vmID: vmID,
                detail: "{\"reason\":\"block io error on \(device) (\(operation))\"}",
                db: dbPool,
            )

        case "DEVICE_TRAY_MOVED":
            let trayout = (data?["tray-open"] as? Bool) ?? false
            if trayout {
                let device = (data?["device"] as? String) ?? "unknown"
                Log.vm.info("Media ejected from \(device)", vm: vmID)
            }

        case "RESET":
            Log.vm.info("VM reset detected", vm: vmID)

        default:
            // Ignore other events (BALLOON_CHANGE, RTC_CHANGE, etc.)
            break
        }
    }
}
