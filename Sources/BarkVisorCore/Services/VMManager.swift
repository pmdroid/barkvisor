import Foundation
import GRDB

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

    public init(qemuPid: Int32, swtpmPid: Int32?) {
        self.qemuPid = qemuPid
        self.swtpmPid = swtpmPid
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
        return VMPidFile(qemuPid: qemu, swtpmPid: swtpm)
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

    public init(id: String, state: String, error: String?) {
        self.id = id
        self.state = state
        self.error = error
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
    /// Same PID already adopted in this process is a no-op so reconnect cannot
    /// drop the live `Process` handle (PAS-90).
    public func registerReconnectedVM(vmID: String, running: RunningVM) {
        if let existing = runningVMs[vmID], existing.pid == running.pid {
            return
        }
        runningVMs[vmID] = running
    }

    public func isRegistered(vmID: String) -> Bool {
        runningVMs[vmID] != nil
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

        // Fail fast if hostfwd ports are already bound (another VM, or orphaned QEMU).
        try Self.assertHostPortsAvailable(for: loaded.vm)

        // Update state to starting and clear pending changes
        try await updateState(vmID: vmID, state: "starting")
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE vms SET pendingChanges = 0 WHERE id = ?", arguments: [vmID])
        }

        // Declared outside do/catch so catch block can clean up swtpm on QEMU failure
        var swtpmProc: Process?

        do {
            let sockets = VMSockets(vmID: vmID)
            sockets.removeStale()

            let launch = try QEMUBuilder.launchConfig(ctx: QEMUBuildContext(
                vm: loaded.vm, disk: loaded.disk, isos: loaded.isos, network: loaded.network,
                additionalDisks: loaded.additionalDisks,
                sockets: sockets,
                bridgeSocketPath: bridgeSocketPath,
            ))
            swtpmProc = try await startSwtpmIfNeeded(launch: launch, vmID: vmID, vmName: loaded.vm.name)

            logLaunchCommand(launch: launch, network: loaded.network, vmName: loaded.vm.name, vmID: vmID)

            let (process, stdoutPipe, stderrPipe) = configureQEMUProcess(launch: launch, vmID: vmID)
            try process.run()
            let pid = process.processIdentifier

            // Write PID file (line 1: QEMU PID, line 2: swtpm PID)
            let swtpmPid = swtpmProc?.processIdentifier ?? -1
            try "\(pid)\n\(swtpmPid)".write(
                to: pidsDir.appendingPathComponent("\(vmID).pid"), atomically: true, encoding: .utf8,
            )

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

            await metricsCollector?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path, pid: pid)
            await guestAgentInventory?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path)
            await qmpEventListener?.start(vmID: vmID, eventSocketPath: sockets.event.path)

            Log.vm.info(
                "VM \(loaded.vm.name) started (PID: \(pid), VNC: \(sockets.vnc.path), Serial: \(sockets.serial.path))",
                vm: vmID,
            )
        } catch {
            cleanupFailedSwtpm(swtpmProc, vmID: vmID)
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

    /// How long to wait for ACPI/guest-agent stop before giving up (no SIGKILL).
    private static let acpiShutdownTimeout: TimeInterval = 60
    /// How long to wait for QEMU to exit after SIGTERM before SIGKILL.
    private static let termGraceTimeout: TimeInterval = 2

    /// Shutdown methods: "acpi" sends ACPI powerdown, "force" kills immediately.
    /// ACPI returns after QMP powerdown. A background task waits for exit but
    /// does not SIGKILL — Force Stop is the only kill path (PAS-90).
    /// Force waits until the QEMU process is dead (or a short hard-kill timeout).
    public func stop(vmID: String, force: Bool, method: String = "acpi") async throws {
        guard let running = runningVMs[vmID] else {
            throw BarkVisorError.vmNotRunning(vmID)
        }

        try await updateState(vmID: vmID, state: "stopping")

        // Mark as expected stop so process monitor treats exit as clean (reconnected VMs)
        await processMonitor?.markExpectedStop(vmID: vmID)

        if IndependentExecution.allowsHardKill(force: force, method: method) {
            Log.vm.info("Force stopping VM \(vmID) (PID \(running.pid))", vm: vmID)
            await hardKill(running: running, vmID: vmID, reason: "force stop")
            return
        }

        // Graceful stop: prefer QEMU Guest Agent (reaches guest userspace), then ACPI power button.
        // PAS-90: ACPI must not escalate to SIGKILL. Force Stop is the only kill path.
        do {
            let methodUsed = try requestGracefulShutdown(running: running, vmID: vmID)
            Log.vm.info(
                "Graceful shutdown requested for VM \(vmID) via \(methodUsed) (PID \(running.pid))",
                vm: vmID,
            )
        } catch {
            Log.vm.error(
                "Graceful shutdown failed for VM \(vmID): \(error) — leaving running (Force Stop required)",
                vm: vmID,
            )
            await processMonitor?.clearExpectedStop(vmID: vmID)
            try await updateState(vmID: vmID, state: "running")
            throw error
        }

        // Wait for graceful shutdown in the background. Do not SIGKILL on timeout.
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.acpiShutdownTimeout)
            while await isProcessAlive(running), Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            if await isProcessAlive(running) {
                Log.vm.warning(
                    "VM \(vmID) still running after \(Int(Self.acpiShutdownTimeout))s ACPI stop — Force Stop required",
                    vm: vmID,
                )
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
        await handleTermination(vmID: vmID, status: status)
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
