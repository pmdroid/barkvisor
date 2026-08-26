import Foundation
import GRDB

extension VMManager {
    // MARK: - Termination Handling

    public func handleTermination(vmID: String, status: Int32, pid: Int32? = nil) async {
        if let pid, let running = runningVMs[vmID], running.pid != pid {
            Log.vm.debug(
                "handleTermination PID \(pid) is not current QEMU \(running.pid) — skipping",
                vm: vmID,
            )
            return
        }
        guard runningVMs[vmID] != nil else {
            Log.vm.debug(
                "handleTermination called for VM \(vmID) but already cleaned up — skipping", vm: vmID,
            )
            return
        }
        await CodingAgentSessionStore.shared.remove(vmID: vmID)

        let newState = status == 0 ? "stopped" : "error"
        let errorMsg = status != 0 ? "QEMU exited with status \(status)" : nil
        if let errorMsg {
            recordHealthError(errorMsg, for: vmID)
        } else {
            clearHealthError(for: vmID)
        }
        Log.vm.info("VM \(vmID) terminated (status: \(status))", vm: vmID)

        if status != 0 {
            Log.vm.error("VM terminated unexpectedly (exit status \(status))", vm: vmID)
            await AuditService.logVMEvent(
                action: VMLifecycleAction.crashed,
                vmID: vmID,
                detail: "{\"reason\":\"exit status \(status)\"}",
                db: dbPool,
            )
        }

        await releasePassthroughGPUs(vmID: vmID)
        await cleanup(vmID: vmID)
        runningVMs.removeValue(forKey: vmID)

        // Stop recording console, metrics, and event listener
        await consoleBuffers?.detach(vmID: vmID)
        await metricsCollector?.stop(vmID: vmID)
        await guestAgentInventory?.stop(vmID: vmID)
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

        await CodingAgentLifecycleService.onTerminated(vmID: vmID, db: dbPool)

        // Notify SSE listeners
        let event = VMStateEvent(id: vmID, state: newState, error: errorMsg)
        await stateStreamService?.broadcast(event: event)
    }

    func releasePassthroughGPUs(vmID: String) async {
        do {
            let devices = try await dbPool.read { db in
                try VM.fetchOne(db, key: vmID)?.decodedGPUDevices ?? []
            }
            GPUPassthroughService.releaseVFIO(devices)
        } catch {
            Log.vm.warning(
                "vfio-pci unbind skipped; could not load GPU list: \(error.localizedDescription)",
                vm: vmID,
            )
        }
    }

    // MARK: - Guest-Initiated Shutdown

    /// Called by QMPEventListener when QEMU reports a guest-initiated SHUTDOWN event.
    /// Updates state to "stopping", sends `quit` to QEMU via QMP to ensure
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

        // Wait for process to exit; hard-kill after 15s
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(15)
            while await isProcessAlive(running), Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            if await isProcessAlive(running) {
                await hardKill(running: running, vmID: vmID, reason: "guest shutdown hang")
            } else {
                await ensureTerminationRecorded(vmID: vmID, running: running, status: 0)
            }
        }
    }

    // MARK: - Process Helpers

    /// Send a signal to the QEMU process. Prefer PID-based kill so reconnected VMs
    /// (where `process` is nil) and native Process-owned VMs behave the same.
    /// Use `SIGKILL` for force-stop — some QEMU builds ignore SIGTERM until guest exit.
    public func terminateProcess(_ running: RunningVM, signal: Int32 = SIGTERM) {
        if signal == SIGTERM, let proc = running.process, proc.isRunning {
            proc.terminate()
        }
        // Always signal by PID as well: Foundation.Process.terminate can be a no-op if the
        // process was not spawned by this Process instance, and reconnected VMs have process == nil.
        kill(running.pid, signal)
    }

    public func isProcessAlive(_ running: RunningVM) -> Bool {
        if let proc = running.process {
            return proc.isRunning
        }
        // For reconnected VMs, also validate it's still a QEMU process (guard against PID reuse)
        guard kill(running.pid, 0) == 0 else { return false }
        guard let path = PlatformProcess.executablePath(pid: running.pid) else { return false }
        return path.contains("qemu-system")
    }

    public static func isSwtpmProcess(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let path = PlatformProcess.executablePath(pid: pid) else { return false }
        return (path as NSString).lastPathComponent.contains("swtpm")
    }

    /// Stop swtpm by Process handle or adopted PID. Guards against PID reuse.
    public static func terminateSwtpm(pid: Int32, vmID: String) {
        guard isSwtpmProcess(pid: pid) else { return }
        kill(pid, SIGTERM)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if isSwtpmProcess(pid: pid) {
                Log.vm.warning(
                    "swtpm (PID \(pid)) for VM \(vmID) did not exit after SIGTERM, sending SIGKILL",
                    vm: vmID,
                )
                kill(pid, SIGKILL)
            }
        }
    }

    public func terminateSwtpm(_ running: RunningVM, vmID: String) {
        if let swtpm = running.swtpmProcess, swtpm.isRunning {
            swtpm.terminate()
            let pid = swtpm.processIdentifier
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if swtpm.isRunning, Self.isSwtpmProcess(pid: pid) {
                    Log.vm.warning(
                        "swtpm (PID \(pid)) for VM \(vmID) did not exit after SIGTERM, sending SIGKILL",
                        vm: vmID,
                    )
                    kill(pid, SIGKILL)
                }
            }
            return
        }
        if let pid = running.swtpmPid {
            Self.terminateSwtpm(pid: pid, vmID: vmID)
        }
    }

    // MARK: - Cleanup

    public func cleanup(vmID: String) async {
        await CodingAgentSessionStore.shared.remove(vmID: vmID)
        if let running = runningVMs[vmID] {
            AgentNetworkCage.removeLinuxFilter(pid: running.pid, vmID: vmID)
            terminateSwtpm(running, vmID: vmID)
        }
        // Remove PID file
        try? FileManager.default.removeItem(at: pidsDir.appendingPathComponent("\(vmID).pid"))
        VMSockets(vmID: vmID).removeStale()
    }
}
