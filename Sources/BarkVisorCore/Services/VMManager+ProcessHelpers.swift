import Foundation
import GRDB
import os

extension VMManager {
    // MARK: - Termination Handling

    public func handleTermination(vmID: String, status: Int32) async {
        // Guard against double-cleanup: if the VM is already removed, another handler got here first
        guard runningVMs[vmID] != nil else {
            Log.vm.debug(
                "handleTermination called for VM \(vmID) but already cleaned up — skipping", vm: vmID,
            )
            return
        }

        let newState = status == 0 ? "stopped" : "error"
        let errorMsg = status != 0 ? "QEMU exited with status \(status)" : nil
        Log.vm.info("VM \(vmID) terminated (status: \(status))", vm: vmID)

        // Log unexpected exits as errors
        if status != 0 {
            Log.vm.error("VM terminated unexpectedly (exit status \(status))", vm: vmID)
        }

        cleanup(vmID: vmID)
        runningVMs.removeValue(forKey: vmID)

        // Stop recording console, metrics, and event listener
        await consoleBuffers?.detach(vmID: vmID)
        await metricsCollector?.stop(vmID: vmID)
        await qmpEventListener?.stop(vmID: vmID)

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE vms SET state = ?, updatedAt = ? WHERE id = ?",
                    arguments: [newState, iso8601.string(from: Date()), vmID],
                )
            }
        } catch {
            Log.vm.error("Failed to update DB state for terminated VM \(vmID): \(error)", vm: vmID)
        }

        // Notify SSE listeners
        let event = VMStateEvent(id: vmID, state: newState, error: errorMsg)
        await stateStreamService?.broadcast(event: event)
    }

    // MARK: - Guest-Initiated Shutdown

    /// Called by QMPEventListener when QEMU reports a guest-initiated SHUTDOWN event.
    /// Updates state to "stopping", sends `quit` to QEMU via the HMP monitor to ensure
    /// the process exits (QEMU can linger after guest halt on macOS HVF), and waits
    /// with a force-kill timeout.
    public func handleGuestShutdown(vmID: String) async {
        guard let running = runningVMs[vmID] else { return }

        // If the VM is already stopping (user-initiated ACPI powerdown), skip —
        // stop() already has its own wait + force-kill timeout.
        let currentState = try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM vms WHERE id = ?", arguments: [vmID])
        }
        if currentState == "stopping" {
            Log.vm.debug(
                "Skipping handleGuestShutdown for VM \(vmID) — already stopping via user action", vm: vmID,
            )
            return
        }

        // Mark as expected stop so process monitor treats exit as clean
        await processMonitor?.markExpectedStop(vmID: vmID)

        do {
            try await updateState(vmID: vmID, state: "stopping")
        } catch {
            Log.vm.error("Failed to update state for guest-shutdown VM \(vmID): \(error)", vm: vmID)
        }

        // Send quit to QEMU via QMP — this tells the process to exit cleanly
        do {
            let qmp = QMPClient(socketPath: running.qmpSocketPath)
            try qmp.connect()
            _ = try qmp.execute("quit")
            qmp.disconnect()
        } catch {
            Log.vm.warning(
                "Failed to send quit to QEMU for VM \(vmID): \(error), will wait for natural exit", vm: vmID,
            )
        }

        // Wait for process to exit, force-kill after 15s
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(15)
            while await isProcessAlive(running), Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            if await isProcessAlive(running) {
                Log.vm.warning("VM \(vmID) did not exit after guest shutdown + quit, terminating", vm: vmID)
                await terminateProcess(running)
            }
            // For reconnected VMs, the dispatch source handles cleanup.
            // Only call handleTermination if dispatch source hasn't already cleaned up.
            if running.reconnected {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await runningVMs[vmID] != nil, await !isProcessAlive(running) {
                    await handleTermination(vmID: vmID, status: 0)
                }
            }
        }
    }

    // MARK: - Process Helpers

    public func terminateProcess(_ running: RunningVM) {
        if let proc = running.process {
            proc.terminate()
        } else {
            kill(running.pid, SIGTERM)
        }
    }

    public func isProcessAlive(_ running: RunningVM) -> Bool {
        if let proc = running.process {
            return proc.isRunning
        }
        // For reconnected VMs, also validate it's still a QEMU process (guard against PID reuse)
        guard kill(running.pid, 0) == 0 else { return false }
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let ret = proc_pidpath(running.pid, &pathBuffer, UInt32(pathBuffer.count))
        guard ret > 0 else { return false }
        let path = pathBuffer.withUnsafeBufferPointer {
            String(bytes: $0.prefix(while: { $0 != 0 }).map(UInt8.init), encoding: .utf8) ?? ""
        }
        return path.contains("qemu-system")
    }

    // MARK: - Cleanup

    public func cleanup(vmID: String) {
        // Terminate swtpm if we have a reference to it
        if let swtpm = runningVMs[vmID]?.swtpmProcess, swtpm.isRunning {
            swtpm.terminate()
            // Give swtpm up to 2s to exit, then SIGKILL
            let pid = swtpm.processIdentifier
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if swtpm.isRunning {
                    Log.vm.warning(
                        "swtpm (PID \(pid)) for VM \(vmID) did not exit after SIGTERM, sending SIGKILL",
                        vm: vmID,
                    )
                    kill(pid, SIGKILL)
                }
            }
        }
        // Remove PID file
        try? FileManager.default.removeItem(at: pidsDir.appendingPathComponent("\(vmID).pid"))
        // Remove sockets
        let shortID = String(vmID.prefix(12))
        for suffix in ["mon", "ser", "qmp", "evt", "ga", "vnc"] {
            try? FileManager.default.removeItem(
                at: Config.socketDir.appendingPathComponent("\(shortID)-\(suffix).sock"),
            )
        }
    }
}
