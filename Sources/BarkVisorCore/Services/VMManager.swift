import Foundation
import GRDB
import os

public struct RunningVM: @unchecked Sendable {
    public let process: Process? // nil for reconnected VMs
    public let pid: Int32
    public let serialSocketPath: String
    public let vncSocketPath: String
    public let monitorSocketPath: String
    public let qmpSocketPath: String
    public let qmpEventSocketPath: String // dedicated socket for persistent event listening
    public let swtpmProcess: Process?
    public let reconnected: Bool // true = adopted from previous app session

    public init(
        process: Process?,
        pid: Int32,
        serialSocketPath: String,
        vncSocketPath: String,
        monitorSocketPath: String,
        qmpSocketPath: String,
        qmpEventSocketPath: String,
        swtpmProcess: Process?,
        reconnected: Bool,
    ) {
        self.process = process
        self.pid = pid
        self.serialSocketPath = serialSocketPath
        self.vncSocketPath = vncSocketPath
        self.monitorSocketPath = monitorSocketPath
        self.qmpSocketPath = qmpSocketPath
        self.qmpEventSocketPath = qmpEventSocketPath
        self.swtpmProcess = swtpmProcess
        self.reconnected = reconnected
    }
}

public struct VMInfo: Sendable {
    public let id: String
    public let name: String
    public let state: String

    public init(id: String, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
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
    public let dbPool: DatabasePool
    public let pidsDir: URL
    public private(set) var consoleBuffers: ConsoleBufferManager?
    public private(set) var metricsCollector: MetricsCollector?
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
    public func registerReconnectedVM(vmID: String, running: RunningVM) {
        runningVMs[vmID] = running
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

        let bridgeSocketPath = try await validateBridgeIfNeeded(network: loaded.network)

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
                vncSock: sockets.vnc, monitorSock: sockets.monitor,
                serialSock: sockets.serial, qmpSock: sockets.qmp,
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
                monitorSocketPath: sockets.monitor.path,
                qmpSocketPath: sockets.qmp.path,
                qmpEventSocketPath: sockets.event.path,
                swtpmProcess: swtpmProc,
                reconnected: false,
            )
            runningVMs[vmID] = running

            // Attach console buffer BEFORE marking state as running,
            // so WebSocket clients see data immediately when they connect
            await consoleBuffers?.attach(vmID: vmID, serialSocketPath: sockets.serial.path)

            try await updateState(vmID: vmID, state: "running")

            await metricsCollector?.start(vmID: vmID, qmpSocketPath: sockets.qmp.path, pid: pid)
            await qmpEventListener?.start(vmID: vmID, eventSocketPath: sockets.event.path)

            Log.vm.info(
                "VM \(loaded.vm.name) started (PID: \(pid), VNC: \(sockets.vnc.path), Serial: \(sockets.serial.path))",
                vm: vmID,
            )
        } catch {
            cleanupFailedSwtpm(swtpmProc, vmID: vmID)
            Log.vm.error("VM start failed: \(error.localizedDescription)", vm: vmID)
            do {
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

    /// Shutdown methods: "acpi" sends ACPI powerdown, "force" kills immediately.
    /// Sends the shutdown signal and returns immediately. A background task handles the wait + force-kill timeout.
    public func stop(vmID: String, force: Bool, method: String = "acpi") async throws {
        guard let running = runningVMs[vmID] else {
            throw BarkVisorError.vmNotRunning(vmID)
        }

        try await updateState(vmID: vmID, state: "stopping")

        // Mark as expected stop so process monitor treats exit as clean (reconnected VMs)
        await processMonitor?.markExpectedStop(vmID: vmID)

        if force || method == "force" {
            Log.vm.info("Force stopping VM \(vmID) (PID \(running.pid))", vm: vmID)
            terminateProcess(running)
            return
        }

        // Send ACPI powerdown via QMP
        Log.vm.info("Sending ACPI powerdown to VM \(vmID) (PID \(running.pid))", vm: vmID)
        do {
            let qmp = QMPClient(socketPath: running.qmpSocketPath)
            try qmp.connect()
            let response = try qmp.execute("system_powerdown")
            qmp.disconnect()
            Log.vm.info("ACPI powerdown sent to VM \(vmID), response: \(response)", vm: vmID)
        } catch {
            Log.vm.error("ACPI powerdown failed for VM \(vmID): \(error)", vm: vmID)
            terminateProcess(running)
            return
        }

        // Wait for graceful shutdown in the background — force kill after 5 minutes
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(300)
            while await isProcessAlive(running), Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            if await isProcessAlive(running) {
                Log.vm.warning(
                    "VM \(vmID) did not shut down gracefully after 5 minutes, sending SIGTERM to force termination",
                    vm: vmID,
                )
                await terminateProcess(running)
            }
            // For reconnected VMs, the dispatch source in VMProcessMonitor handles cleanup.
            // Only call handleTermination here if the dispatch source won't fire
            // (i.e., the process already exited before the source was set up).
            if running.reconnected {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Only clean up if the VM is still in our runningVMs (dispatch source hasn't already handled it)
                if await runningVMs[vmID] != nil, await !isProcessAlive(running) {
                    await handleTermination(vmID: vmID, status: 0)
                }
            }
        }
    }

    // MARK: - Restart

    public func restart(vmID: String) async throws {
        if runningVMs[vmID] != nil {
            try await stop(vmID: vmID, force: false)
            // Wait up to 5 minutes for the guest to shut down gracefully — never force kill on restart.
            let deadline = Date().addingTimeInterval(300)
            while runningVMs[vmID] != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if runningVMs[vmID] != nil {
                throw BarkVisorError.timeout("VM \(vmID) did not stop within 5 minutes — restart aborted")
            }
        }
        try await start(vmID: vmID)
    }
}
