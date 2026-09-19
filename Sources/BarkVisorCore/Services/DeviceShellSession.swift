#if !os(Windows)
    import Foundation

    public struct DeviceShellRequest: Sendable, Equatable {
        public var account: String
        public var cols: Int
        public var rows: Int

        public static let defaultCols = 80
        public static let defaultRows = 24

        public init(
            account: String,
            cols: Int = DeviceShellRequest.defaultCols,
            rows: Int = DeviceShellRequest.defaultRows,
        ) {
            self.account = account
            self.cols = cols
            self.rows = rows
        }
    }

    public enum DeviceShellSessionState: String, Sendable {
        case idle
        case running
        case exited
    }

    public final class DeviceShellSession: @unchecked Sendable {
        public static let shellExitInput = "exit\n"

        private let lock = NSLock()
        private let launcher: any ExecPTYLaunching
        private var state: DeviceShellSessionState = .idle
        private var child: (any ExecPTYHandling)?
        private var exitCode: Int32?

        public init(launcher: any ExecPTYLaunching = LiveExecPTYLauncher()) {
            self.launcher = launcher
        }

        public var currentState: DeviceShellSessionState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        public var lastExitCode: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return exitCode
        }

        public func start(
            _ request: DeviceShellRequest,
            euid: UInt32 = DeviceLoginAccount.currentEUID(),
            platform: DeviceLoginAccount.PlatformKind = DeviceLoginAccount.currentPlatform,
            onData: @escaping @Sendable ([UInt8]) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void,
        ) throws {
            guard let record = DeviceLoginAccount.spawnRecord(
                name: request.account,
                euid: euid,
                platform: platform,
            ) else {
                throw BarkVisorError.badRequest("Unknown or disallowed account")
            }
            guard record.uid != 0 else {
                throw BarkVisorError.badRequest("Unknown or disallowed account")
            }
            let shell = DeviceLoginAccount.loginShellPath(for: record)
            let argv0 = (shell as NSString).lastPathComponent
            let env = DeviceLoginAccount.environment(for: record, shellPath: shell)
            let credentials = euid == 0 ? DeviceLoginAccount.credentials(for: record) : nil
            lock.lock()
            guard state == .idle else {
                lock.unlock()
                throw BarkVisorError.badRequest("DeviceShellSession already started")
            }
            lock.unlock()
            let pty = try launcher.launch(
                executable: shell,
                arguments: ["-il"],
                cols: request.cols,
                rows: request.rows,
                argv0: argv0.isEmpty ? "sh" : argv0,
                environment: env,
                credentials: credentials,
                workingDirectory: record.home,
                onData: onData,
                onExit: { [weak self] code in
                    guard let self else { return }
                    self.lock.lock()
                    self.state = .exited
                    self.exitCode = code
                    self.lock.unlock()
                    onExit(code)
                },
            )
            lock.lock()
            child = pty
            state = .running
            lock.unlock()
        }

        public func write(_ bytes: [UInt8]) {
            lock.lock()
            let live = child
            lock.unlock()
            live?.write(bytes)
        }

        public func resize(cols: Int, rows: Int) {
            lock.lock()
            let live = child
            lock.unlock()
            live?.resize(cols: cols, rows: rows)
        }

        public func requestShellExit() {
            lock.lock()
            let live = state == .running ? child : nil
            lock.unlock()
            live?.write(Array(Self.shellExitInput.utf8))
        }

        public func terminate() {
            lock.lock()
            let live = child
            lock.unlock()
            live?.terminate()
        }
    }
#endif
