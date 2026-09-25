import ArgumentParser
import BarkVisor
import BarkVisorCore
import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import ucrt
    import WinSDK
#endif
import Logging

#if os(Windows)
    nonisolated(unsafe) var windowsShutdownEvent: HANDLE?
    nonisolated(unsafe) var windowsServiceStatusHandle: SERVICE_STATUS_HANDLE?
    nonisolated(unsafe) var windowsServiceStatus = SERVICE_STATUS()
    nonisolated(unsafe) var windowsServiceStoppedEvent: HANDLE?
    nonisolated(unsafe) let windowsServiceReady = DispatchSemaphore(value: 0)
    nonisolated(unsafe) let windowsServiceDispatcherDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var windowsServiceName: [WCHAR] = Array("BarkVisor".utf16) + [0]

    func windowsReportServiceStatus(
        _ state: DWORD,
        accepted: Bool,
        win32Exit: DWORD = 0,
        specific: DWORD = 0,
    ) {
        windowsServiceStatus.dwServiceType = DWORD(SERVICE_WIN32_OWN_PROCESS)
        windowsServiceStatus.dwCurrentState = state
        windowsServiceStatus.dwControlsAccepted = accepted
            ? DWORD(SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN)
            : 0
        windowsServiceStatus.dwWin32ExitCode = win32Exit
        windowsServiceStatus.dwServiceSpecificExitCode = specific
        windowsServiceStatus.dwCheckPoint = 0
        let pending = state == DWORD(SERVICE_STOP_PENDING) || state == DWORD(SERVICE_START_PENDING)
        windowsServiceStatus.dwWaitHint = pending ? 30_000 : 0
        if let handle = windowsServiceStatusHandle {
            _ = SetServiceStatus(handle, &windowsServiceStatus)
        }
    }

    let windowsServiceControlProc: LPHANDLER_FUNCTION = { control in
        if control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN {
            windowsReportServiceStatus(DWORD(SERVICE_STOP_PENDING), accepted: false)
            if let event = windowsShutdownEvent {
                _ = SetEvent(event)
            }
        }
    }

    let windowsServiceMainProc: LPSERVICE_MAIN_FUNCTIONW = { _, _ in
        var name: [WCHAR] = Array("BarkVisor".utf16) + [0]
        windowsServiceStatusHandle = name.withUnsafeMutableBufferPointer { buf in
            RegisterServiceCtrlHandlerW(buf.baseAddress, windowsServiceControlProc)
        }
        windowsReportServiceStatus(DWORD(SERVICE_START_PENDING), accepted: false)
        windowsServiceReady.signal()
        if let event = windowsServiceStoppedEvent {
            _ = WaitForSingleObject(event, INFINITE)
        }
        windowsReportServiceStatus(DWORD(SERVICE_STOPPED), accepted: false)
    }

    enum WindowsService {
        static func attach() {
            if windowsShutdownEvent == nil {
                windowsShutdownEvent = CreateEventW(nil, true, false, nil)
            }
            if windowsServiceStoppedEvent == nil {
                windowsServiceStoppedEvent = CreateEventW(nil, true, false, nil)
            }
            _ = SetConsoleCtrlHandler({ _ in
                if let event = windowsShutdownEvent {
                    _ = SetEvent(event)
                }
                return true
            }, true)

            Thread.detachNewThread {
                let started = windowsServiceName.withUnsafeMutableBufferPointer { buf -> Bool in
                    var entries = [
                        SERVICE_TABLE_ENTRYW(
                            lpServiceName: buf.baseAddress,
                            lpServiceProc: windowsServiceMainProc,
                        ),
                        SERVICE_TABLE_ENTRYW(lpServiceName: nil, lpServiceProc: nil),
                    ]
                    return entries.withUnsafeMutableBufferPointer { table in
                        StartServiceCtrlDispatcherW(table.baseAddress)
                    }
                }
                if !started {
                    windowsServiceReady.signal()
                }
                windowsServiceDispatcherDone.signal()
            }
            windowsServiceReady.wait()
        }

        static func reportRunning() {
            windowsReportServiceStatus(DWORD(SERVICE_RUNNING), accepted: true)
        }

        static func reportStartFailed() {
            windowsReportServiceStatus(
                DWORD(SERVICE_STOPPED),
                accepted: false,
                win32Exit: DWORD(ERROR_SERVICE_SPECIFIC_ERROR),
                specific: 1,
            )
            notifyStopped()
        }

        static func notifyStopped() {
            if let event = windowsServiceStoppedEvent {
                _ = SetEvent(event)
            }
            windowsServiceDispatcherDone.wait()
        }
    }
#endif

/// Pipe for signal→async communication.
/// A raw POSIX signal handler writes here; the async main reads from it.
/// We avoid DispatchSource entirely because Swift 6 strict concurrency
/// checks executor isolation on GCD callbacks, causing dispatch_assert_queue crashes.
nonisolated(unsafe) var signalPipeFDs: [Int32] = [0, 0]

@main
struct BarkVisorCLI: AsyncParsableCommand {
    static let configuration: CommandConfiguration = {
        let role = DaemonRole.from(executablePath: ProcessInfo.processInfo.arguments[0])
        return CommandConfiguration(
            commandName: role.commandName,
            abstract: role.serveFrontend
                ? "BarkVisor Device daemon"
                : "BarkVisor Device daemon (API-only, no SPA)",
            subcommands: [
                Serve.self,
                Join.self,
                Doctor.self,
                HostnetExpire.self,
                DaemonCommand.self,
                ServerCommand.self,
            ],
            defaultSubcommand: Serve.self,
        )
    }()
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the BarkVisor Device daemon (default).",
    )

    func run() async throws {
        await runDaemon()
    }
}

/// Console-local Home join (PAS-180). Posts the pairing offer to this
/// Device's host API — not through Home.
struct Join: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Join a Home from this Device.",
        discussion: """
        1. On the other Device, Settings → Pairing → Add a Device, pick the \
        address this Device can reach, and copy the full barkvisor:// offer.
        2. Run this command with that offer (not the short printed code).
        3. This posts to http://127.0.0.1:7777/api/pairing/join on this Device.
        """,
    )

    @Option(
        name: .long,
        help: "Full barkvisor://pair/v1?… offer from the other Device (not the short code).",
    )
    var code: String

    func run() async throws {
        let result = try await LocalPairingJoin.post(
            offer: code,
            client: URLSessionPairingHTTPClient(),
        )
        FileHandle.standardOutput.write(
            Data("Joined Home. Peer Device \(result.peerHostId)\n".utf8),
        )
    }
}

/// Read-only Device checks. Never mutates the host.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read-only Device capability checks.",
        discussion: """
        Probes daemon uid, QEMU, /dev/kvm, swtpm, /api/health, and host-bridge \
        facts (Linux helper/setuid/br0 or macOS socket_vmnet). Never applies \
        network or package changes. The SPA can fetch the same report from \
        GET /api/system/doctor.
        """,
    )

    @Flag(name: .long, help: "Print JSON.")
    var json = false

    func run() async throws {
        let report = DoctorService.probe()
        if json {
            try FileHandle.standardOutput.write(DoctorService.jsonData(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data(DoctorService.renderText(report).utf8))
        }
        if !report.ok {
            throw ExitCode(1)
        }
    }
}

struct HostnetExpire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hostnet-expire",
        abstract: "Revert expired host-network Keep windows.",
    )

    func run() async throws {
        try Config.ensureDirectories()
        let database = try AppDatabase(path: Config.dbPath.path)
        try database.migrate()
        await HostNetworkPendingReaper.expire(db: database.pool)
    }
}

func configureLogging() {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = .debug
        return handler
    }
}

func runDaemon() async {
    configureLogging()

    let sockets = Config.socketDir
    if PlatformPaths.socketDirIsPackagingOwned(sockets),
       !PlatformPaths.isWritableDirectory(sockets) {
        let message = """
        Socket directory \(sockets.path) is missing or not writable. \
        Packaging must create this directory (Homebrew postinstall, pkg, or systemd); \
        the Device daemon cannot mkdir /var/run or /run. \
        Homebrew: sudo "$(brew --prefix barkvisor)/share/barkvisor/postinstall" \
        && sudo brew services restart barkvisor
        """
        Log.server.critical("\(message)")
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    #if os(Windows)
        WindowsService.attach()
    #else
        pipe(&signalPipeFDs)
        signal(SIGTERM) { _ in
            var b: UInt8 = 1
            write(signalPipeFDs[1], &b, 1)
        }
        signal(SIGINT) { _ in
            var b: UInt8 = 1
            write(signalPipeFDs[1], &b, 1)
        }
    #endif

    var serverLogger = Logger(label: "barkvisor.server")
    serverLogger[metadataKey: "version"] = Logger.MetadataValue(stringLiteral: Config.version)

    let server = VaporServer()

    do {
        try await server.start()
        #if os(Windows)
            WindowsService.reportRunning()
        #endif
    } catch {
        Log.server.critical("Server failed to start: \(error)")
        FileHandle.standardError.write(Data("Server failed to start: \(error)\n".utf8))
        #if os(Windows)
            WindowsService.reportStartFailed()
        #endif
        exit(1)
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            #if os(Windows)
                if let event = windowsShutdownEvent {
                    _ = WaitForSingleObject(event, INFINITE)
                }
            #else
                var b: UInt8 = 0
                _ = read(signalPipeFDs[0], &b, 1)
            #endif
            cont.resume()
        }
    }
    Log.server.info("Received signal, shutting down gracefully...")

    #if os(Windows)
        _ = SetConsoleCtrlHandler({ _ in
            _exit(1)
            return true
        }, true)
    #else
        signal(SIGTERM) { _ in _exit(1) }
        signal(SIGINT) { _ in _exit(1) }
    #endif

    // Graceful shutdown with hard timeout
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await server.stop() }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            Log.server.error("Graceful shutdown timed out after 10s, forcing exit")
            _exit(1)
        }
        await group.next()
        group.cancelAll()
    }

    #if os(Windows)
        WindowsService.notifyStopped()
        if let event = windowsShutdownEvent {
            CloseHandle(event)
            windowsShutdownEvent = nil
        }
        if let event = windowsServiceStoppedEvent {
            CloseHandle(event)
            windowsServiceStoppedEvent = nil
        }
    #else
        close(signalPipeFDs[0])
        close(signalPipeFDs[1])
    #endif
}

nonisolated(unsafe) var managementSignalFDs: [Int32] = [0, 0]

func armManagementShutdown() {
    #if !os(Windows)
        var created = [Int32](repeating: 0, count: 2)
        pipe(&created)
        managementSignalFDs = created
        signal(SIGTERM) { _ in
            var byte: UInt8 = 1
            write(managementSignalFDs[1], &byte, 1)
        }
        signal(SIGINT) { _ in
            var byte: UInt8 = 1
            write(managementSignalFDs[1], &byte, 1)
        }
    #endif
}

func signalManagementShutdown() {
    #if !os(Windows)
        guard managementSignalFDs.count == 2 else { return }
        var byte: UInt8 = 1
        _ = write(managementSignalFDs[1], &byte, 1)
    #endif
}

func waitForManagementShutdown() async {
    #if !os(Windows)
        let readFD = managementSignalFDs[0]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var byte: UInt8 = 0
                _ = read(readFD, &byte, 1)
                cont.resume()
            }
        }
    #endif
}

func superviseUntilSignal(
    run: @escaping @Sendable () async throws -> Void,
    stop: @escaping @Sendable () -> Void,
) async throws {
    #if os(Windows)
        try await run()
    #else
        armManagementShutdown()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await run()
            }
            group.addTask {
                await waitForManagementShutdown()
                stop()
            }
            do {
                try await group.next()
            } catch {
                stop()
                signalManagementShutdown()
                group.cancelAll()
                throw error
            }
            stop()
            signalManagementShutdown()
            group.cancelAll()
        }
    #endif
}

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run BarkDaemon on the local management socket.",
    )

    func run() async throws {
        #if os(Windows)
            throw ServiceProcessRoleError.unavailable
        #else
            setenv("BARKVISOR_PROCESS_ROLE", ServiceProcessRole.barkDaemon.rawValue, 1)
            let euid = WorkloadPrivilegeDrop.currentEUID()
            let permissions = SocketPermissionPlan.forDaemonEUID(euid)
            let policy = LocalManagementPolicy(
                allowedPeerUIDs: LocalManagementPeers.allowlist(
                    daemonEUID: euid,
                    serverUID: WorkloadPrivilegeDrop.uid(forUser: "barkvisor"),
                ),
                memberships: [],
                resources: ResourcePolicy(allowedRoots: [], allowedMounts: [], allowedDevices: []),
            )
            let database = try AppDatabase(path: Config.dbPath.path)
            try database.migrate()
            let manager = VMManager(dbPool: database.pool)
            let tasks = BackgroundTaskManager()
            let operations = try DurableOperationFile(
                url: Config.dataDir.appendingPathComponent("socket-operations.json"),
            )
            let driver = LiveWorkloadSocketDriver(
                db: database.pool,
                vmManager: manager,
                tasks: tasks,
            )
            let facts = try await DaemonRecovery.facts(db: database.pool)
            let plan = await DaemonRecovery.reconcile(
                records: operations.all(),
                running: facts.running,
                present: facts.present,
            )
            for record in plan.records {
                await operations.save(record)
            }
            for command in plan.commands {
                guard let current = await operations.find(operationID: command.operationID) else { continue }
                var finished = current
                do {
                    let snapshot = try await driver.perform(command)
                    finished.phase = "completed"
                    finished.state = snapshot.state
                    finished.runtime = snapshot.runtime
                } catch {
                    finished.phase = "failed"
                    finished.state = "failed"
                }
                await operations.save(finished)
            }
            let server = LocalManagementSocketServer(
                path: ManagementSocketPath.path(socketDir: Config.socketDir),
                session: LocalManagementSession(
                    policy: policy,
                    operationStore: operations,
                    workloadDriver: driver,
                ),
                directoryMode: permissions.directoryMode,
                socketMode: permissions.socketMode,
            )
            try await superviseUntilSignal {
                try await server.run()
            } stop: {
                server.stop()
            }
        #endif
    }
}

struct ServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Run BarkServer. Refuses root and does not open the management database.",
    )

    func run() async throws {
        #if os(Windows)
            throw ServiceProcessRoleError.unavailable
        #else
            setenv("BARKVISOR_PROCESS_ROLE", ServiceProcessRole.barkServer.rawValue, 1)
            try BarkServerStartup.refuseRoot(euid: WorkloadPrivilegeDrop.currentEUID())
            let handshake = try LocalManagementSocketClient.exchange(
                path: ManagementSocketPath.path(socketDir: Config.socketDir),
                request: LocalManagementRequest(
                    requestId: "startup",
                    operationId: "startup",
                    name: "protocolVersion",
                ),
            )
            try BarkServerStartup.requireHandshake(handshake)
            let publicServer = PublicBarkServer(
                socketPath: ManagementSocketPath.path(socketDir: Config.socketDir),
            )
            try await superviseUntilSignal {
                try await publicServer.run(httpPort: Config.port, deviceTLSPort: Config.agentPort)
            } stop: {
                publicServer.stop()
            }
        #endif
    }
}
