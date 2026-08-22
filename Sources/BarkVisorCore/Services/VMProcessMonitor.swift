import Foundation
import GRDB

public actor VMProcessMonitor {
    #if os(macOS)
        private var processMonitorSources: [String: DispatchSourceProcess] = [:]
    #else
        private var processMonitorTasks: [String: Task<Void, Never>] = [:]
    #endif
    private var expectedStops: Set<String> = []
    private let dbPool: DatabasePool
    private let pidsDir: URL
    private weak var vmManager: VMManager?
    private var consoleBuffers: ConsoleBufferManager?
    private var metricsCollector: MetricsCollector?
    private var guestAgentInventory: GuestAgentInventory?
    private var stateStreamService: VMStateStreamService?
    private var qmpEventListener: QMPEventListener?

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.pidsDir = Config.dataDir.appendingPathComponent("pids")
    }

    public func setVMManager(_ manager: VMManager) {
        vmManager = manager
    }

    public func setConsoleBuffers(_ buffers: ConsoleBufferManager) {
        consoleBuffers = buffers
    }

    public func setMetricsCollector(_ collector: MetricsCollector) {
        metricsCollector = collector
    }

    public func setGuestAgentInventory(_ inventory: GuestAgentInventory) {
        guestAgentInventory = inventory
    }

    public func setStateStreamService(_ service: VMStateStreamService) {
        stateStreamService = service
    }

    public func setQMPEventListener(_ listener: QMPEventListener) {
        qmpEventListener = listener
    }

    // MARK: - Reconnect or Cleanup

    public func reconnectOrCleanup() async {
        guard let enumerator = FileManager.default.enumerator(atPath: pidsDir.path) else { return }

        var reconnectedIDs: Set<String> = []

        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix(".pid") else { continue }
            let vmID = String(file.dropLast(4))
            if await tryReconnectVM(vmID: vmID, pidFile: pidsDir.appendingPathComponent(file)) {
                reconnectedIDs.insert(vmID)
            }
        }

        await resetStaleVMStates(excluding: reconnectedIDs)

        if !reconnectedIDs.isEmpty {
            Log.vm.info("Reconnected to \(reconnectedIDs.count) running VM(s)")
        }
    }

    private func tryReconnectVM(vmID: String, pidFile: URL) async -> Bool {
        guard let content = try? String(contentsOf: pidFile, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: pidFile)
            return false
        }

        guard let pids = VMPidFile.parse(content) else {
            try? FileManager.default.removeItem(at: pidFile)
            return false
        }
        let pid = pids.qemuPid
        let processAlive = kill(pid, 0) == 0
        let isQEMU = processAlive && isQEMUProcess(pid: pid)
        let alreadyRegistered = await vmManager?.isRegistered(vmID: vmID) == true
        let vmRecord = try? await dbPool.read { db in
            try VM.fetchOne(db, key: vmID)
        }

        switch IndependentExecution.reconnectAction(
            alreadyRegistered: alreadyRegistered,
            processAlive: processAlive,
            isQEMU: isQEMU,
            hasDBRecord: vmRecord != nil,
        ) {
        case .skipAlreadyRegistered:
            Log.vm.info("VM \(vmID): already adopted, skipping reconnect", vm: vmID)
            return true
        case .cleanupDead:
            Log.vm.info("VM \(vmID): process \(pid) no longer running, cleaning up", vm: vmID)
            cleanupDeadVM(vmID: vmID)
            return false
        case .cleanupPidReuse:
            Log.vm.warning("VM \(vmID): PID \(pid) is not QEMU (PID reuse), cleaning up", vm: vmID)
            cleanupDeadVM(vmID: vmID)
            return false
        case .cleanupOrphanNoRecord:
            Log.vm.warning("VM \(vmID): no DB record, killing orphaned process", vm: vmID)
            kill(pid, SIGTERM)
            cleanupDeadVM(vmID: vmID)
            return false
        case .adopt:
            break
        }

        guard let vmRecord else { return false }

        let sockets = VMSockets(vmID: vmID)
        if !FileManager.default.fileExists(atPath: sockets.qmp.path) {
            Log.vm.warning(
                "VM \(vmID): QMP socket missing — adopting live QEMU without kill (PAS-90)",
                vm: vmID,
            )
        }

        let swtpmPid = pids.swtpmPid.flatMap { candidate in
            VMManager.isSwtpmProcess(pid: candidate) ? candidate : nil
        }
        let running = RunningVM(
            process: nil,
            pid: pid,
            serialSocketPath: sockets.serial.path,
            vncSocketPath: sockets.vnc.path,
            qmpSocketPath: sockets.qmp.path,
            qmpEventSocketPath: sockets.event.path,
            swtpmProcess: nil,
            reconnected: true,
            swtpmPid: swtpmPid,
        )
        await vmManager?.registerReconnectedVM(vmID: vmID, running: running)

        await consoleBuffers?.attach(vmID: vmID, serialSocketPath: sockets.serial.path)
        await metricsCollector?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path, pid: pid)
        await guestAgentInventory?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path)
        await qmpEventListener?.start(vmID: vmID, eventSocketPath: sockets.event.path)

        watchProcess(vmID: vmID, pid: pid)

        Log.vm.info(
            "Reconnected to VM \(vmRecord.name) (PID: \(pid), VNC: \(sockets.vnc.path))",
            vm: vmID,
        )
        return true
    }

    private func resetStaleVMStates(excluding reconnectedIDs: Set<String>) async {
        do {
            try await dbPool.write { db in
                let staleVMs = try VM.filter(["running", "starting", "stopping"].contains(Column("state")))
                    .fetchAll(db)
                for vm in staleVMs where !reconnectedIDs.contains(vm.id) {
                    try db.execute(
                        sql: "UPDATE vms SET state = 'stopped', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), vm.id],
                    )
                }
            }
        } catch {
            Log.vm.error("Failed to reset stale VM states: \(error)")
        }
    }

    /// Mark a VM as being intentionally stopped, so the process monitor treats exit as clean.
    public func markExpectedStop(vmID: String) {
        expectedStops.insert(vmID)
    }

    public func clearExpectedStop(vmID: String) {
        expectedStops.remove(vmID)
    }

    // MARK: - Process Monitor (reconnected VMs)

    /// Watch a reconnected VM's PID for exit (kqueue/DispatchSource on macOS, poll on Linux).
    public func watchProcess(vmID: String, pid: pid_t) {
        #if os(macOS)
            guard processMonitorSources[vmID] == nil else { return }
            let source = DispatchSource.makeProcessSource(
                identifier: pid, eventMask: .exit, queue: .global(),
            )
            source.setEventHandler { [weak self] in
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleWatchedProcessExit(vmID: vmID, pid: pid)
                }
            }
            source.setCancelHandler {} // prevent crash on dealloc
            source.resume()
            processMonitorSources[vmID] = source
        #else
            guard processMonitorTasks[vmID] == nil else { return }
            processMonitorTasks[vmID] = Task { [weak self] in
                // Poll until process exits or watch is cancelled.
                while !Task.isCancelled {
                    if kill(pid, 0) != 0 {
                        await self?.handleWatchedProcessExit(vmID: vmID, pid: pid)
                        return
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        #endif
    }

    private func handleWatchedProcessExit(vmID: String, pid: pid_t) async {
        let wasExpected = consumeExpectedStop(vmID: vmID)
        let exitStatus: Int32 = wasExpected ? 0 : -1
        Log.vm.info(
            "Reconnected VM \(vmID) (PID: \(pid)) has exited (expected: \(wasExpected))", vm: vmID,
        )
        if let vmManager {
            await vmManager.handleTermination(vmID: vmID, status: exitStatus)
        }
        removeProcessSource(vmID: vmID)
    }

    private func consumeExpectedStop(vmID: String) -> Bool {
        return expectedStops.remove(vmID) != nil
    }

    public func removeProcessSource(vmID: String) {
        #if os(macOS)
            if let source = processMonitorSources.removeValue(forKey: vmID) {
                source.cancel()
            }
        #else
            if let task = processMonitorTasks.removeValue(forKey: vmID) {
                task.cancel()
            }
        #endif
    }

    public func stopAllProcessSources() {
        #if os(macOS)
            for (_, source) in processMonitorSources {
                source.cancel()
            }
            processMonitorSources.removeAll()
        #else
            for (_, task) in processMonitorTasks {
                task.cancel()
            }
            processMonitorTasks.removeAll()
        #endif
    }

    // MARK: - Private Helpers

    private func isQEMUProcess(pid: Int32) -> Bool {
        guard let path = PlatformProcess.executablePath(pid: pid) else { return false }
        return path.contains("qemu-system")
    }

    private func cleanupDeadVM(vmID: String) {
        let pidFile = pidsDir.appendingPathComponent("\(vmID).pid")
        if let content = try? String(contentsOf: pidFile, encoding: .utf8),
           let pids = VMPidFile.parse(content),
           let swtpmPid = pids.swtpmPid {
            VMManager.terminateSwtpm(pid: swtpmPid, vmID: vmID)
        }
        try? FileManager.default.removeItem(at: pidFile)
        VMSockets(vmID: vmID).removeStale()
        // Retry DB update up to 3 times to prevent orphaned running state
        for attempt in 1 ... 3 {
            do {
                try dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE vms SET state = 'stopped', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), vmID],
                    )
                }
                return
            } catch {
                if attempt == 3 {
                    Log.vm.critical(
                        "Failed to update DB for dead VM \(vmID) after 3 attempts: \(error). VM may appear stuck as 'running'.",
                        vm: vmID,
                    )
                } else {
                    Log.vm.warning(
                        "DB update for dead VM \(vmID) failed (attempt \(attempt)/3): \(error)", vm: vmID,
                    )
                }
            }
        }
    }
}
