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
    private struct Run {
        let generation: UInt64
        let task: Task<Void, Never>
        let client: QMPClient
    }

    private var runs: [String: Run] = [:]
    private var nextGeneration: UInt64 = 0
    private weak var vmManager: VMManager?
    private var stateStreamService: VMStateStreamService?
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

    // MARK: - Lifecycle

    public func start(vmID: String, eventSocketPath: String) {
        stop(vmID: vmID)

        let generation = nextGeneration
        nextGeneration &+= 1
        let client = QMPClient(socketPath: eventSocketPath, timeoutSeconds: 3)
        let task = Task {
            await self.run(vmID: vmID, generation: generation, socketPath: eventSocketPath, client: client)
        }
        runs[vmID] = Run(generation: generation, task: task, client: client)
    }

    public func stop(vmID: String) {
        guard let run = runs.removeValue(forKey: vmID) else { return }
        run.task.cancel()
        run.client.interrupt()
    }

    public func stopAll() {
        for (_, run) in runs {
            run.task.cancel()
            run.client.interrupt()
        }
        runs.removeAll()
    }

    // MARK: - Event Loop

    /// Thread-safe wrapper for transferring non-Sendable QMP event data across isolation boundaries.
    private struct QMPEventBox: @unchecked Sendable {
        let events: [[String: Any]]
        let closed: Bool
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

    private func run(vmID: String, generation: UInt64, socketPath: String, client: QMPClient) async {
        while !Task.isCancelled, isCurrent(vmID: vmID, generation: generation) {
            if await waitForSocket(path: socketPath) {
                if await connect(client: client), isCurrent(vmID: vmID, generation: generation) {
                    client.setReceiveTimeoutSeconds(0)
                    await readEvents(vmID: vmID, generation: generation, client: client)
                }
            }
            client.disconnect()
            if Task.isCancelled || !isCurrent(vmID: vmID, generation: generation) {
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        client.disconnect()
    }

    private func waitForSocket(path: String) async -> Bool {
        var waitedNanos: UInt64 = 0
        while !Task.isCancelled {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            if waitedNanos >= 2_000_000_000 {
                return false
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
            waitedNanos &+= 10_000_000
        }
        return false
    }

    private func connect(client: QMPClient) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            do {
                try client.connect()
                return true
            } catch {
                client.disconnect()
                return false
            }
        }.value
    }

    private func readEvents(vmID: String, generation: UInt64, client: QMPClient) async {
        while !Task.isCancelled, isCurrent(vmID: vmID, generation: generation) {
            let box = await Task.detached(priority: .utility) { () -> QMPEventBox in
                guard let message = try? client.readMessagePublic() else {
                    return QMPEventBox(events: [], closed: true)
                }
                return QMPEventBox(
                    events: message["event"] == nil ? [] : [message],
                    closed: false,
                )
            }.value
            guard !Task.isCancelled, isCurrent(vmID: vmID, generation: generation) else { return }
            if box.closed { return }
            for event in box.events {
                await handleEvent(vmID: vmID, generation: generation, event: event)
                guard !Task.isCancelled, isCurrent(vmID: vmID, generation: generation) else { return }
            }
        }
    }

    // MARK: - Event Handlers

    private func handleEvent(vmID: String, generation: UInt64, event: [String: Any]) async {
        guard let eventType = event["event"] as? String else { return }
        guard isCurrent(vmID: vmID, generation: generation) else { return }
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
