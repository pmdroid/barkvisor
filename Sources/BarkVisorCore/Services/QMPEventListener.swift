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
    private var tasks: [String: Task<Void, Never>] = [:]
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
        guard tasks[vmID] == nil else { return }

        tasks[vmID] = Task {
            // Wait for QEMU to create the event socket
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            while !Task.isCancelled {
                await self.listenLoop(vmID: vmID, socketPath: eventSocketPath)

                // If we get here, the connection dropped — reconnect after a short delay
                // (unless the task was cancelled, meaning the VM was stopped)
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func stop(vmID: String) {
        tasks[vmID]?.cancel()
        tasks.removeValue(forKey: vmID)
    }

    public func stopAll() {
        for (_, task) in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    // MARK: - Event Loop

    /// Thread-safe wrapper for transferring non-Sendable QMP event data across isolation boundaries.
    private struct QMPEventBox: @unchecked Sendable {
        let events: [[String: Any]]
    }

    private func listenLoop(vmID: String, socketPath: String) async {
        // Run blocking QMP I/O off the cooperative thread pool.
        let box = await Task.detached(priority: .utility) { () -> QMPEventBox in
            let client = QMPClient(socketPath: socketPath, timeoutSeconds: 30)
            do {
                try client.connect()
            } catch {
                return QMPEventBox(events: [])
            }
            defer { client.disconnect() }

            var collected: [[String: Any]] = []

            // Sit on the socket and read events until disconnected or timeout
            // The 30s socket timeout means we'll cycle through here periodically,
            // which lets us check for cancellation
            while !Task.isCancelled {
                do {
                    let msg = try client.readMessagePublic()
                    if msg["event"] != nil {
                        collected.append(msg)
                    }
                    // Responses are unexpected on the event socket — ignore them
                } catch {
                    // Timeout or disconnect — break and let outer loop reconnect
                    break
                }
            }
            return QMPEventBox(events: collected)
        }.value

        for event in box.events {
            await handleEvent(vmID: vmID, event: event)
        }
    }

    // MARK: - Event Handlers

    private func handleEvent(vmID: String, event: [String: Any]) async {
        guard let eventType = event["event"] as? String else { return }
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
                await vmManager?.handleGuestShutdown(vmID: vmID)
            }

        case "GUEST_PANICKED":
            let action = (data?["action"] as? String) ?? "unknown"
            Log.vm.error("Kernel panic detected (action: \(action))", vm: vmID)

            // Update DB state to error — the QEMU process may still be running
            do {
                try await dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE vms SET state = 'error', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), vmID],
                    )
                }
                let event = VMStateEvent(id: vmID, state: "error", error: "Kernel panic")
                await stateStreamService?.broadcast(event: event)
            } catch {
                Log.vm.error("Failed to update DB for panicked VM \(vmID): \(error)", vm: vmID)
            }

        case "BLOCK_IO_ERROR":
            let device = (data?["device"] as? String) ?? "unknown"
            let operation = (data?["operation"] as? String) ?? "unknown"
            let action = (data?["action"] as? String) ?? "unknown"
            Log.vm.error("Disk I/O error on \(device): \(operation) (action: \(action))", vm: vmID)

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
