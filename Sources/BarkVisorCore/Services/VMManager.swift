import Foundation
import GRDB
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct RunningVM: @unchecked Sendable {
    public let process: Process? // nil for reconnected VMs
    public let pid: Int32
    public let serialSocketPath: String
    public let vncSocketPath: String
    public let qmpSocketPath: String
    public let qmpEventSocketPath: String // dedicated socket for persistent event listening
    public let swtpmProcess: Process?
    /// PID of swtpm when this VM was adopted (`process` / `swtpmProcess` are nil).
    public let swtpmPid: Int32?
    public let reconnected: Bool // true = adopted from previous app session

    public init(
        process: Process?,
        pid: Int32,
        serialSocketPath: String,
        vncSocketPath: String,
        qmpSocketPath: String,
        qmpEventSocketPath: String,
        swtpmProcess: Process?,
        reconnected: Bool,
        swtpmPid: Int32? = nil,
    ) {
        self.process = process
        self.pid = pid
        self.serialSocketPath = serialSocketPath
        self.vncSocketPath = vncSocketPath
        self.qmpSocketPath = qmpSocketPath
        self.qmpEventSocketPath = qmpEventSocketPath
        self.swtpmProcess = swtpmProcess
        self.reconnected = reconnected
        if let swtpmPid, swtpmPid > 0 {
            self.swtpmPid = swtpmPid
        } else if let swtpmProcess {
            self.swtpmPid = swtpmProcess.processIdentifier
        } else {
            self.swtpmPid = nil
        }
    }
}

/// QEMU + optional swtpm PIDs written as two lines under `pids/`.
public struct VMPidFile: Equatable, Sendable {
    public let qemuPid: Int32
    public let swtpmPid: Int32?
    /// Loopback ttyd host port (PAS-272). Optional third line; absent on older files.
    public let codingAgentHostPort: Int?

    public init(qemuPid: Int32, swtpmPid: Int32?, codingAgentHostPort: Int? = nil) {
        self.qemuPid = qemuPid
        self.swtpmPid = swtpmPid
        self.codingAgentHostPort = codingAgentHostPort
    }

    public func serialized() -> String {
        var lines = ["\(qemuPid)", "\(swtpmPid ?? -1)"]
        if let codingAgentHostPort {
            lines.append("\(codingAgentHostPort)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ content: String) -> VMPidFile? {
        let lines = content.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let first = lines.first, let qemu = Int32(first), qemu > 0 else { return nil }
        var swtpm: Int32?
        if lines.count > 1, let second = Int32(lines[1]), second > 0 {
            swtpm = second
        }
        var codingPort: Int?
        if lines.count > 2, let third = Int(lines[2]), (1 ... 65_535).contains(third) {
            codingPort = third
        }
        return VMPidFile(qemuPid: qemu, swtpmPid: swtpm, codingAgentHostPort: codingPort)
    }
}

public struct VMLoadResult: Sendable {
    public let vm: VM
    public let disk: Disk
    public let isos: [VMImage]
    public let network: Network?
    public let additionalDisks: [Disk]
}

public struct VMStateEvent: Codable, Sendable {
    public let id: String
    public let state: String
    public let error: String?
    public let pendingImageId: String?
    public let downloadPercent: Int?

    public init(
        id: String,
        state: String,
        error: String?,
        pendingImageId: String? = nil,
        downloadPercent: Int? = nil,
    ) {
        self.id = id
        self.state = state
        self.error = error
        self.pendingImageId = pendingImageId
        self.downloadPercent = downloadPercent
    }
}

public actor VMManager: VMStateQuerying {
    public var runningVMs: [String: RunningVM] = [:]
    var startingVMs: Set<String> = [] // guards against concurrent start across await points
    /// Last QEMU/start error per VM (PAS-79). Not persisted — Wave 0 signal cache.
    var lastHealthErrors: [String: String] = [:]
    public let dbPool: DatabasePool
    public let pidsDir: URL
    public private(set) var consoleBuffers: ConsoleBufferManager?
    public private(set) var metricsCollector: MetricsCollector?
    public private(set) var guestAgentInventory: GuestAgentInventory?
    public private(set) var stateStreamService: VMStateStreamService?
    public private(set) var processMonitor: VMProcessMonitor?
    public private(set) var qmpEventListener: QMPEventListener?

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.pidsDir = Config.dataDir.appendingPathComponent("pids")
        try? FileManager.default.createDirectory(at: pidsDir, withIntermediateDirectories: true)
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

    public func setProcessMonitor(_ monitor: VMProcessMonitor) {
        processMonitor = monitor
    }

    public func setQMPEventListener(_ listener: QMPEventListener) {
        qmpEventListener = listener
    }

    /// Register a reconnected VM (called by VMProcessMonitor during reconnection).
    public func registerReconnectedVM(
        vmID: String,
        running: RunningVM,
        codingAgentHostPort: Int? = nil,
    ) async {
        runningVMs[vmID] = running
        let args = PlatformProcess.arguments(pid: running.pid)
        if let port = CodingAgentSession.recoveredTerminalHostPort(
            qemuArguments: args,
            pidFilePort: codingAgentHostPort,
        ) {
            await CodingAgentSessionStore.shared.record(vmID: vmID, terminalHostPort: port)
        } else if CodingAgentSession.wantsWebTerminal(
            userData: CloudInitService.storedUserData(vmID: vmID),
        ) {
            Log.vm.warning(
                "VM \(vmID): reconnect did not recover ttyd loopback host port",
                vm: vmID,
            )
        }
    }

    // MARK: - Start

    // swiftlint:disable:next function_body_length
    public func start(vmID: String) async throws {
        guard runningVMs[vmID] == nil, !startingVMs.contains(vmID) else {
            throw BarkVisorError.vmAlreadyRunning(vmID)
        }

        // Claim immediately to block concurrent starts across await suspension points
        startingVMs.insert(vmID)
        defer { startingVMs.remove(vmID) }

        // Load VM and related records
        let loaded = try await loadVM(id: vmID)
        guard loaded.vm.state == "stopped" || loaded.vm.state == "error" else {
            throw BarkVisorError.vmAlreadyRunning(vmID)
        }

        // PAS-48: block foreign-arch guests (portable or overlay) before QEMU / state flip.
        // Overlay guestType stays in overridesJson; QEMUBuilder launches the merged guest.
        let effective = try EffectiveWorkloadPipeline.evaluate(vm: loaded.vm)
        try PlatformCapabilities.requireCompatibleGuestArch(
            GuestProfiles.require(effective.launchGuestType).arch,
        )

        let bridgeSocketPath = try await validateBridgeIfNeeded(network: loaded.network)

        let diskPaths = [loaded.disk.path] + loaded.additionalDisks.map(\.path)
        try BlockDeviceService.requireHostDeviceReadWrite(paths: diskPaths)
        if try await adoptExistingQEMUOrConflict(
            vmID: vmID,
            vmName: loaded.vm.name,
            diskPaths: diskPaths,
        ) {
            return
        }

        try Self.assertHostPortsAvailable(for: loaded.vm)

        // Update state to starting and clear pending changes
        try await updateState(vmID: vmID, state: "starting")
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE vms SET pendingChanges = 0 WHERE id = ?", arguments: [vmID])
        }

        // Declared outside do/catch so catch block can clean up swtpm on QEMU failure
        var swtpmProc: Process?
        var qemuProc: Process?

        do {
            let sockets = VMSockets(vmID: vmID)
            sockets.removeStale()

            let userData = CloudInitService.storedUserData(vmID: vmID)
            var loopbackHostfwds: [QEMULoopbackForward] = []
            if CodingAgentSession.wantsWebTerminal(userData: userData) {
                let occupied = await CodingAgentSessionStore.shared.occupiedHostPorts()
                let hostPort = try await PortRegistry.nextFree(
                    preferred: CodingAgentImage.webTerminalPort,
                    proto: "tcp",
                    excludingVM: vmID,
                    extraOccupied: occupied,
                    db: dbPool,
                )
                loopbackHostfwds.append(
                    QEMULoopbackForward(
                        hostPort: hostPort,
                        guestPort: CodingAgentImage.webTerminalPort,
                    ),
                )
                // Dropped in cleanup() (handleTermination, stopAll, shutdownAll).
                await CodingAgentSessionStore.shared.record(vmID: vmID, terminalHostPort: hostPort)
            }

            let launch = try QEMUBuilder.launchConfig(ctx: QEMUBuildContext(
                vm: loaded.vm, disk: loaded.disk, isos: loaded.isos, network: loaded.network,
                additionalDisks: loaded.additionalDisks,
                sockets: sockets,
                bridgeSocketPath: bridgeSocketPath,
                loopbackHostfwds: loopbackHostfwds,
            ))
            swtpmProc = try await startSwtpmIfNeeded(launch: launch, vmID: vmID, vmName: loaded.vm.name)

            logLaunchCommand(launch: launch, network: loaded.network, vmName: loaded.vm.name, vmID: vmID)

            let (process, stdoutPipe, stderrPipe, droppedUser) = configureQEMUProcess(launch: launch, vmID: vmID)
            qemuProc = process
            try process.run()
            let pid = process.processIdentifier
            if (try? WorkloadClass.parse(loaded.vm.workloadClass)) == .agent {
                do {
                    try AgentNetworkCage.applyLinuxFilter(vmID: vmID, pid: pid, launchUser: droppedUser)
                } catch {
                    process.terminate()
                    throw error
                }
            }

            try await waitForQMPSocket(
                process: process,
                qmpSock: sockets.qmp,
                stderrPipe: stderrPipe,
                stdoutPipe: stdoutPipe,
                vmID: vmID,
            )

            attachPipeHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, vmID: vmID)

            try await waitForVNCAndSerialSockets(
                process: process,
                vncSock: sockets.vnc,
                serialSock: sockets.serial,
                vmID: vmID,
            )

            sockets.setOwnerOnlyPermissions()

            let pidFile = VMPidFile(
                qemuPid: pid,
                swtpmPid: swtpmProc?.processIdentifier,
                codingAgentHostPort: loopbackHostfwds.first?.hostPort,
            )
            try pidFile.serialized().write(
                to: pidsDir.appendingPathComponent("\(vmID).pid"), atomically: true, encoding: .utf8,
            )

            let running = RunningVM(
                process: process,
                pid: pid,
                serialSocketPath: sockets.serial.path,
                vncSocketPath: sockets.vnc.path,
                qmpSocketPath: sockets.qmp.path,
                qmpEventSocketPath: sockets.event.path,
                swtpmProcess: swtpmProc,
                reconnected: false,
            )
            runningVMs[vmID] = running

            // Attach console buffer BEFORE marking state as running,
            // so WebSocket clients see data immediately when they connect
            await consoleBuffers?.attach(vmID: vmID, serialSocketPath: sockets.serial.path)

            clearHealthError(for: vmID)
            try await updateState(vmID: vmID, state: "running")
            await CodingAgentLifecycleService.onStart(vm: loaded.vm, db: dbPool)

            await metricsCollector?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path, pid: pid)
            await guestAgentInventory?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path)
            await qmpEventListener?.start(vmID: vmID, eventSocketPath: sockets.event.path)

            Log.vm.info(
                "VM \(loaded.vm.name) started (PID: \(pid), VNC: \(sockets.vnc.path), Serial: \(sockets.serial.path))",
                vm: vmID,
            )
        } catch {
            let writeLock: Bool = {
                if case let .processSpawnFailed(message)? = error as? BarkVisorError {
                    return QEMUArgv.reportsWriteLock(message)
                }
                return false
            }()
            await CodingAgentSessionStore.shared.remove(vmID: vmID)
            cleanupFailedSwtpm(swtpmProc, vmID: vmID)

            if writeLock {
                qemuProc?.terminationHandler = nil
                do {
                    if try await adoptExistingQEMUOrConflict(
                        vmID: vmID,
                        vmName: loaded.vm.name,
                        diskPaths: diskPaths,
                        excludingPids: Set([qemuProc?.processIdentifier].compactMap(\.self)),
                    ) {
                        Log.vm.info(
                            "VM \(loaded.vm.name): adopted existing QEMU after disk-lock failure",
                            vm: vmID,
                        )
                        return
                    }
                } catch let conflictError {
                    GPUPassthroughService.releaseVFIO(loaded.vm.decodedGPUDevices)
                    recordHealthError(conflictError.localizedDescription, for: vmID)
                    try? await updateState(vmID: vmID, state: "error", error: conflictError.localizedDescription)
                    throw conflictError
                }
            } else if let proc = qemuProc, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }

            GPUPassthroughService.releaseVFIO(loaded.vm.decodedGPUDevices)
            Log.vm.error("VM start failed: \(error.localizedDescription)", vm: vmID)
            do {
                recordHealthError(error.localizedDescription, for: vmID)
                try await updateState(vmID: vmID, state: "error", error: error.localizedDescription)
            } catch let stateError {
                Log.vm.critical(
                    """
                    Failed to set VM \(vmID) to error state after start failure: \
                    \(stateError.localizedDescription). VM may be permanently stuck in 'starting' state.
                    """,
                )
            }
            throw error
        }
    }

    // MARK: - Stop

    /// Graceful ACPI wait before escalating to hard kill (seconds).
    private static let acpiShutdownTimeout: TimeInterval = 60
    /// How long to wait for QEMU to exit after SIGTERM before SIGKILL.
    private static let termGraceTimeout: TimeInterval = 2

    /// Shutdown methods: "acpi" sends ACPI powerdown, "force" kills immediately.
    /// ACPI returns after QMP powerdown; a background task escalates to hard kill if needed.
    /// Force waits until the QEMU process is dead (or a short hard-kill timeout).
    public func stop(vmID: String, force: Bool, method: String = "acpi") async throws {
        // Occupancy stays until handleTermination. ACPI/graceful stop leaves
        // QEMU (and the loopback ttyd hostfwd) bound.
        guard let running = runningVMs[vmID] else {
            throw BarkVisorError.vmNotRunning(vmID)
        }
        let intent = (force || method == "force")
            ? CodingAgentLifecycle.forceReason
            : CodingAgentLifecycle.stopReason
        await CodingAgentLifecycleService.markStopIntent(vmID: vmID, reason: intent, db: dbPool)

        try await updateState(vmID: vmID, state: "stopping")

        // Mark as expected stop so process monitor treats exit as clean (reconnected VMs)
        await processMonitor?.markExpectedStop(vmID: vmID)

        if force || method == "force" {
            Log.vm.info("Force stopping VM \(vmID) (PID \(running.pid))", vm: vmID)
            await hardKill(running: running, vmID: vmID, reason: "force stop")
            return
        }

        // Graceful stop: prefer QEMU Guest Agent (reaches guest userspace), then ACPI power button.
        do {
            let methodUsed = try requestGracefulShutdown(running: running, vmID: vmID)
            Log.vm.info(
                "Graceful shutdown requested for VM \(vmID) via \(methodUsed) (PID \(running.pid))",
                vm: vmID,
            )
        } catch {
            Log.vm.error(
                "Graceful shutdown failed for VM \(vmID): \(error) — hard-killing", vm: vmID,
            )
            await hardKill(running: running, vmID: vmID, reason: "graceful shutdown failed")
            return
        }

        // Wait for graceful shutdown in the background — hard kill after acpiShutdownTimeout.
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.acpiShutdownTimeout)
            while await isProcessAlive(running), Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            if await isProcessAlive(running) {
                Log.vm.warning(
                    "VM \(vmID) did not shut down after \(Int(Self.acpiShutdownTimeout))s graceful stop, hard-killing",
                    vm: vmID,
                )
                await hardKill(running: running, vmID: vmID, reason: "graceful shutdown timeout")
            } else {
                await ensureTerminationRecorded(vmID: vmID, running: running, status: 0)
            }
        }
    }

    /// Ask the guest to power off.
    /// 1) `guest-shutdown` via QEMU Guest Agent when the agent socket is live (best — systemd sees it).
    /// 2) QMP `system_powerdown` (ACPI power button) as fallback.
    /// Returns a short label of which path was used.
    func requestGracefulShutdown(running: RunningVM, vmID: String) throws -> String {
        let gaPath = VMSockets(qmpSocketPath: running.qmpSocketPath)?.guestAgent.path
            ?? VMSockets(vmID: vmID).guestAgent.path

        if FileManager.default.fileExists(atPath: gaPath) {
            do {
                try GuestAgentChannel.shutdown(socketPath: gaPath)
                return "guest-agent"
            } catch {
                Log.vm.info(
                    "QGA guest-shutdown unavailable for VM \(vmID): \(error) — falling back to ACPI",
                    vm: vmID,
                )
            }
        } else {
            Log.vm.info(
                "No guest-agent socket for VM \(vmID) at \(gaPath) — using ACPI system_powerdown",
                vm: vmID,
            )
        }

        let qmp = QMPClient(socketPath: running.qmpSocketPath)
        try qmp.connect()
        defer { qmp.disconnect() }
        let response = try qmp.execute("system_powerdown")
        Log.vm.info("ACPI system_powerdown response for VM \(vmID): \(response)", vm: vmID)
        return "acpi-powerdown"
    }

    /// Hard-stop QEMU: prefer QMP `quit`, then SIGTERM, then SIGKILL. Ensures reconnected VMs
    /// get a clean `handleTermination` if the process monitor does not fire.
    func hardKill(running: RunningVM, vmID: String, reason: String) async {
        Log.vm.info("Hard-kill VM \(vmID) (PID \(running.pid)): \(reason)", vm: vmID)

        // 1) QMP quit — cleanest when the monitor socket still works
        do {
            let qmp = QMPClient(socketPath: running.qmpSocketPath)
            try qmp.connect()
            _ = try qmp.execute("quit")
            qmp.disconnect()
            Log.vm.info("QMP quit sent to VM \(vmID)", vm: vmID)
        } catch {
            Log.vm.debug("QMP quit failed for VM \(vmID): \(error)", vm: vmID)
        }

        // 2) SIGTERM (Process.terminate or kill)
        if isProcessAlive(running) {
            terminateProcess(running, signal: SIGTERM)
        }

        let termDeadline = Date().addingTimeInterval(Self.termGraceTimeout)
        while isProcessAlive(running), Date() < termDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // 3) SIGKILL — QEMU (and some guests) can ignore SIGTERM for a long time
        if isProcessAlive(running) {
            Log.vm.warning("VM \(vmID) still alive after TERM, sending SIGKILL", vm: vmID)
            terminateProcess(running, signal: SIGKILL)
            let killDeadline = Date().addingTimeInterval(3)
            while isProcessAlive(running), Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if isProcessAlive(running) {
            Log.vm.error("VM \(vmID) (PID \(running.pid)) still alive after SIGKILL", vm: vmID)
        } else {
            await ensureTerminationRecorded(vmID: vmID, running: running, status: 0)
        }
    }

    /// Record termination if the process monitor has not already cleaned up (esp. reconnected VMs).
    func ensureTerminationRecorded(vmID: String, running: RunningVM, status: Int32) async {
        // Brief yield so DispatchSource/poll can win the race when it fires.
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard runningVMs[vmID] != nil else { return }
        guard !isProcessAlive(running) else { return }
        await handleTermination(vmID: vmID, status: status, pid: running.pid)
    }

    // MARK: - Restart

    public func restart(vmID: String) async throws {
        if runningVMs[vmID] != nil {
            try await stop(vmID: vmID, force: false)
            // Wait for ACPI path (or hard-kill escalation) to finish.
            let deadline = Date().addingTimeInterval(Self.acpiShutdownTimeout + 15)
            while runningVMs[vmID] != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if runningVMs[vmID] != nil {
                // Last resort for restart
                if let running = runningVMs[vmID] {
                    await hardKill(running: running, vmID: vmID, reason: "restart timeout")
                }
            }
            if runningVMs[vmID] != nil {
                throw BarkVisorError.timeout("VM \(vmID) did not stop — restart aborted")
            }
        }
        try await start(vmID: vmID)
    }
}
