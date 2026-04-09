import Foundation
import GRDB
import os

extension VMManager {
    // MARK: - Stop All (explicit user action — force)

    public func stopAll() async {
        // Stop process sources first to prevent dispatch source handlers from racing
        await processMonitor?.stopAllProcessSources()

        for (vmID, running) in runningVMs {
            Log.vm.info("Stopping VM \(vmID)", vm: vmID)
            // SIGTERM first
            terminateProcess(running)
            // Wait up to 5s for graceful exit
            let deadline = Date().addingTimeInterval(5)
            while isProcessAlive(running), Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Escalate to SIGKILL if still alive
            if isProcessAlive(running) {
                Log.vm.warning(
                    "VM \(vmID) (PID \(running.pid)) did not exit after SIGTERM, sending SIGKILL", vm: vmID,
                )
                kill(running.pid, SIGKILL)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Also kill swtpm if it's still running
            if let swtpm = running.swtpmProcess, swtpm.isRunning {
                swtpm.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if swtpm.isRunning {
                    Log.vm.warning(
                        "swtpm (PID \(swtpm.processIdentifier)) for VM \(vmID) did not exit after SIGTERM, sending SIGKILL",
                        vm: vmID,
                    )
                    kill(swtpm.processIdentifier, SIGKILL)
                }
            }
            cleanup(vmID: vmID)

            // Update DB state (including reconnected VMs that have no terminationHandler)
            do {
                try await dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE vms SET state = 'stopped', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), vmID],
                    )
                }
            } catch {
                Log.vm.error(
                    "Failed to update DB state to 'stopped' for VM \(vmID) during stopAll: \(error)", vm: vmID,
                )
            }
        }
        runningVMs.removeAll()
    }

    // MARK: - Graceful Shutdown All (ACPI powerdown with timeout)

    /// Sends ACPI powerdown to all running VMs and waits up to `timeout` seconds.
    /// Returns the names of VMs that were shut down.
    public func shutdownAll(timeout: TimeInterval = 30) async -> [String] {
        let vmsToShutdown = runningVMs
        guard !vmsToShutdown.isEmpty else { return [] }

        // Stop process sources first to prevent dispatch source handlers from racing
        await processMonitor?.stopAllProcessSources()

        var shutdownNames: [String] = []

        // Send ACPI powerdown to all VMs
        for (vmID, running) in vmsToShutdown {
            let vmName = await (try? dbPool.read { db in try VM.fetchOne(db, key: vmID)?.name }) ?? vmID
            shutdownNames.append(vmName)

            // Send ACPI powerdown via QMP
            Log.vm.info("Sending ACPI powerdown to \(vmName) (PID \(running.pid))", vm: vmID)
            do {
                let qmp = QMPClient(socketPath: running.qmpSocketPath)
                try qmp.connect()
                _ = try qmp.execute("system_powerdown")
                qmp.disconnect()
            } catch {
                Log.vm.warning("ACPI powerdown failed for \(vmName): \(error)", vm: vmID)
            }
        }

        // Wait for all to exit
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillRunning = vmsToShutdown.filter { isProcessAlive($0.value) }
            if stillRunning.isEmpty { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Force kill any that didn't shut down
        for (vmID, running) in vmsToShutdown {
            if isProcessAlive(running) {
                Log.vm.warning("VM \(vmID) did not shut down in time, force killing", vm: vmID)
                kill(running.pid, SIGKILL)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            cleanup(vmID: vmID)
            runningVMs.removeValue(forKey: vmID)

            do {
                try await dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE vms SET state = 'stopped', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), vmID],
                    )
                }
            } catch {
                Log.vm.critical(
                    """
                    Failed to update DB state to 'stopped' for VM \(vmID) during shutdownAll: \
                    \(error.localizedDescription). DB may show VM as 'running' despite being killed.
                    """,
                )
            }
        }

        return shutdownNames
    }

    // MARK: - Detach All (app shutdown — leave VMs running)

    public func detachAll() async {
        for (vmID, _) in runningVMs {
            await consoleBuffers?.detach(vmID: vmID)
            await metricsCollector?.stop(vmID: vmID)
        }
        await qmpEventListener?.stopAll()
        await processMonitor?.stopAllProcessSources()
        runningVMs.removeAll()
        // Leave PID files, sockets, and DB state intact
    }
}
