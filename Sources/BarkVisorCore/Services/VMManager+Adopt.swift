import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

extension VMManager {
    @discardableResult
    func adoptExistingQEMUOrConflict(
        vmID: String,
        vmName: String,
        diskPaths: [String],
        processes: [QEMUArgv.ProcessEntry]? = nil,
        excludingPids: Set<Int32> = [],
    ) async throws -> Bool {
        let pidFileURL = pidsDir.appendingPathComponent("\(vmID).pid")
        if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
            if let previous = VMPidFile.parse(content) {
                let pid = previous.qemuPid
                let parsed = PlatformProcess.arguments(pid: pid).flatMap { QEMUArgv(arguments: $0) }
                let owned = kill(pid, 0) == 0 && (parsed?.uuid.map {
                    $0.caseInsensitiveCompare(vmID) == .orderedSame
                } ?? true)
                if owned {
                    try await adoptRunningProcess(vmID: vmID, pid: pid, argv: parsed, previousPids: previous)
                    Log.vm.info("VM \(vmName): adopted existing QEMU (PID \(pid)) via pidfile", vm: vmID)
                    return true
                }
                if let swtpmPid = previous.swtpmPid {
                    Self.terminateSwtpm(pid: swtpmPid, vmID: vmID)
                }
            }
            try? FileManager.default.removeItem(at: pidFileURL)
        }

        let snapshot = (processes ?? QEMUProcessTable.qemuProcesses())
            .filter { !excludingPids.contains($0.pid) }
        switch QEMUArgv.diskHolder(diskPaths: diskPaths, vmID: vmID, processes: snapshot) {
        case let .selfProcess(pid):
            guard kill(pid, 0) == 0 else { return false }
            let parsed = PlatformProcess.arguments(pid: pid).flatMap { QEMUArgv(arguments: $0) }
            let previous = Self.readPidFile(pidsDir: pidsDir, vmID: vmID)
            try await adoptRunningProcess(vmID: vmID, pid: pid, argv: parsed, previousPids: previous)
            Log.vm.info("VM \(vmName): adopted existing QEMU (PID \(pid)) holding this Workload's disk", vm: vmID)
            return true
        case let .foreign(pid, holderName):
            throw BarkVisorError.conflict(Self.diskConflictMessage(
                vmName: vmName,
                pid: pid,
                holderName: holderName,
            ))
        case nil:
            return false
        }
    }

    func adoptRunningProcess(
        vmID: String,
        pid: Int32,
        argv: QEMUArgv?,
        previousPids: VMPidFile?,
    ) async throws {
        let canonical = VMSockets(vmID: vmID)
        let qmpPaths = argv?.qmpSocketPaths ?? []
        let serialPath = argv?.serialSocketPath ?? canonical.serial.path
        let vncPath = argv?.vncSocketPath ?? canonical.vnc.path
        let qmpPath = qmpPaths.first ?? canonical.qmp.path
        let eventPath = qmpPaths.count > 1 ? qmpPaths[1] : canonical.event.path

        let swtpmPid = previousPids?.swtpmPid.flatMap { Self.isSwtpmProcess(pid: $0) ? $0 : nil }
        let rewritten = VMPidFile(
            qemuPid: pid,
            swtpmPid: swtpmPid,
            codingAgentHostPort: previousPids?.codingAgentHostPort,
        )
        try? rewritten.serialized().write(
            to: pidsDir.appendingPathComponent("\(vmID).pid"), atomically: true, encoding: .utf8,
        )

        await registerReconnectedVM(
            vmID: vmID,
            running: RunningVM(
                process: nil,
                pid: pid,
                serialSocketPath: serialPath,
                vncSocketPath: vncPath,
                qmpSocketPath: qmpPath,
                qmpEventSocketPath: eventPath,
                swtpmProcess: nil,
                reconnected: true,
                swtpmPid: swtpmPid,
            ),
            codingAgentHostPort: previousPids?.codingAgentHostPort,
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: serialPath) {
            await consoleBuffers?.attach(vmID: vmID, serialSocketPath: serialPath)
        }
        if fm.fileExists(atPath: qmpPath) {
            await metricsCollector?.start(vmID: vmID, qmpSocketPath: qmpPath, pid: pid)
            await guestAgentInventory?.start(vmID: vmID, qmpSocketPath: qmpPath)
        }
        if fm.fileExists(atPath: eventPath) {
            await qmpEventListener?.start(vmID: vmID, eventSocketPath: eventPath)
        }

        await processMonitor?.watchProcess(vmID: vmID, pid: pid)

        clearHealthError(for: vmID)
        try await updateState(vmID: vmID, state: "running")
    }

    static func readPidFile(pidsDir: URL, vmID: String) -> VMPidFile? {
        guard let content = try? String(contentsOf: pidsDir.appendingPathComponent("\(vmID).pid"), encoding: .utf8)
        else { return nil }
        return VMPidFile.parse(content)
    }

    private static func diskConflictMessage(vmName: String, pid: Int32, holderName: String?) -> String {
        let owner = holderName.map { " (\($0))" } ?? ""
        return "Workload \(vmName) cannot start: its disk is locked by another Workload\(owner) "
            + "(QEMU PID \(pid)). Stop that Workload first."
    }
}
