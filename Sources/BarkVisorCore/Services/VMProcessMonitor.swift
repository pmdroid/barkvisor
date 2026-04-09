import Foundation
import GRDB
import os

public actor VMProcessMonitor {
    private var processMonitorSources: [String: DispatchSourceProcess] = [:]
    private var expectedStops: Set<String> = []
    private let dbPool: DatabasePool
    private let pidsDir: URL
    private weak var vmManager: VMManager?
    private var consoleBuffers: ConsoleBufferManager?
    private var metricsCollector: MetricsCollector?
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

        let lines = content.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard let firstLine = lines.first, let pid = Int32(firstLine) else {
            try? FileManager.default.removeItem(at: pidFile)
            return false
        }

        guard kill(pid, 0) == 0 else {
            Log.vm.info("VM \(vmID): process \(pid) no longer running, cleaning up", vm: vmID)
            cleanupDeadVM(vmID: vmID)
            return false
        }

        guard isQEMUProcess(pid: pid) else {
            Log.vm.warning("VM \(vmID): PID \(pid) is not QEMU (PID reuse), cleaning up", vm: vmID)
            cleanupDeadVM(vmID: vmID)
            return false
        }

        let shortID = String(vmID.prefix(12))
        let qmpSock = Config.socketDir.appendingPathComponent("\(shortID)-qmp.sock").path
        guard FileManager.default.fileExists(atPath: qmpSock) else {
            Log.vm.warning("VM \(vmID): sockets missing, killing orphaned process", vm: vmID)
            kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            cleanupDeadVM(vmID: vmID)
            return false
        }

        let vmRecord = try? await dbPool.read { db in
            try VM.fetchOne(db, key: vmID)
        }
        guard let vmRecord else {
            Log.vm.warning("VM \(vmID): no DB record, killing orphaned process", vm: vmID)
            kill(pid, SIGTERM)
            cleanupDeadVM(vmID: vmID)
            return false
        }

        let vncSock = Config.socketDir.appendingPathComponent("\(shortID)-vnc.sock").path
        let monSock = Config.socketDir.appendingPathComponent("\(shortID)-mon.sock").path
        let serSock = Config.socketDir.appendingPathComponent("\(shortID)-ser.sock").path
        let evtSock = Config.socketDir.appendingPathComponent("\(shortID)-evt.sock").path
        let running = RunningVM(
            process: nil,
            pid: pid,
            serialSocketPath: serSock,
            vncSocketPath: vncSock,
            monitorSocketPath: monSock,
            qmpSocketPath: qmpSock,
            qmpEventSocketPath: evtSock,
            swtpmProcess: nil,
            reconnected: true,
        )
        await vmManager?.registerReconnectedVM(vmID: vmID, running: running)

        await consoleBuffers?.attach(vmID: vmID, serialSocketPath: serSock)
        await metricsCollector?.start(vmID: vmID, qmpSocketPath: qmpSock, pid: pid)
        await qmpEventListener?.start(vmID: vmID, eventSocketPath: evtSock)

        watchProcess(vmID: vmID, pid: pid)

        Log.vm.info("Reconnected to VM \(vmRecord.name) (PID: \(pid), VNC: \(vncSock))", vm: vmID)
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

    // MARK: - Process Monitor (for reconnected VMs via dispatch source)

    /// Watch a reconnected VM's PID for exit using kqueue (via DispatchSource).
    public func watchProcess(vmID: String, pid: pid_t) {
        guard processMonitorSources[vmID] == nil else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(),
        )
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                let wasExpected = await consumeExpectedStop(vmID: vmID)
                let exitStatus: Int32 = wasExpected ? 0 : -1
                Log.vm.info(
                    "Reconnected VM \(vmID) (PID: \(pid)) has exited (expected: \(wasExpected))", vm: vmID,
                )
                if let vmManager = await vmManager {
                    await vmManager.handleTermination(vmID: vmID, status: exitStatus)
                }
                await removeProcessSource(vmID: vmID)
            }
        }
        source.setCancelHandler {} // prevent crash on dealloc
        source.resume()
        processMonitorSources[vmID] = source
    }

    private func consumeExpectedStop(vmID: String) -> Bool {
        return expectedStops.remove(vmID) != nil
    }

    public func removeProcessSource(vmID: String) {
        if let source = processMonitorSources.removeValue(forKey: vmID) {
            source.cancel()
        }
    }

    public func stopAllProcessSources() {
        for (_, source) in processMonitorSources {
            source.cancel()
        }
        processMonitorSources.removeAll()
    }

    // MARK: - Private Helpers

    private func isQEMUProcess(pid: Int32) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let ret = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard ret > 0 else { return false }
        let path = pathBuffer.withUnsafeBufferPointer {
            String(bytes: $0.prefix(while: { $0 != 0 }).map(UInt8.init), encoding: .utf8) ?? ""
        }
        return path.contains("qemu-system")
    }

    private func cleanupDeadVM(vmID: String) {
        try? FileManager.default.removeItem(at: pidsDir.appendingPathComponent("\(vmID).pid"))
        let shortID = String(vmID.prefix(12))
        for suffix in ["mon", "ser", "qmp", "evt", "ga", "vnc"] {
            try? FileManager.default.removeItem(
                at: Config.socketDir.appendingPathComponent("\(shortID)-\(suffix).sock"),
            )
        }
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
