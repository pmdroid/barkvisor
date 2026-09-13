#if !os(Windows)
    import Foundation

    /// The exec child, abstracted so controller/hop tests never touch Docker or
    /// a real PTY. Mirrors `PTYProcess`'s surface.
    public protocol ExecPTYHandling: Sendable {
        func write(_ bytes: [UInt8])
        func resize(cols: Int, rows: Int)
        func terminate()
        var isRunning: Bool { get }
    }

    /// Spawns the `docker exec -it` child. `LiveExecPTYLauncher` uses a real
    /// `PTYProcess`; tests inject a fake that echoes scripted bytes.
    public protocol ExecPTYLaunching: Sendable {
        func launch(
            executable: String,
            arguments: [String],
            onData: @escaping @Sendable ([UInt8]) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void,
        ) throws -> any ExecPTYHandling
    }

    extension PTYProcess: ExecPTYHandling {}

    public struct LiveExecPTYLauncher: ExecPTYLaunching {
        public init() {}

        public func launch(
            executable: String,
            arguments: [String],
            onData: @escaping @Sendable ([UInt8]) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void,
        ) throws -> any ExecPTYHandling {
            let pty = PTYProcess()
            pty.configure(onData: onData, onExit: onExit)
            try pty.start(executable: executable, arguments: arguments)
            return pty
        }
    }

    public struct DockerExecRequest: Sendable, Equatable {
        /// Container name as reported by `docker compose ps` — never raw user
        /// input, and re-validated against a conservative charset before execv.
        public var container: String
        /// Shell inside the container.
        public var shell: String
        public var cols: Int
        public var rows: Int

        public init(container: String, shell: String = "sh", cols: Int = 80, rows: Int = 24) {
            self.container = container
            self.shell = shell
            self.cols = cols
            self.rows = rows
        }

        /// Container/shell names go straight into `execv` argv, so allow only
        /// image-safe characters starting alphanumerically (blocks `-flag`
        /// injection, path traversal, and `..`-style names).
        public static func isSafeExecutableName(_ name: String) -> Bool {
            guard !name.isEmpty, name.count <= 255 else { return false }
            guard let first = name.unicodeScalars.first else { return false }
            let letters = CharacterSet.letters.union(CharacterSet.decimalDigits)
            guard letters.contains(first) else { return false }
            let allowed = letters.union(CharacterSet(charactersIn: "._-"))
            return name.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    public enum DockerExecSessionState: String, Sendable {
        case idle
        case running
        case exited
    }

    /// Owns one `docker exec -it <container> <shell>` PTY from spawn to reap
    /// (issue #609). `start` installs the handlers before forking, so no output
    /// can be missed; the WebSocket bridge (`WebSocketHopFarEnding`, resize
    /// control frames) lives in the server target's `DockerExecHop`.
    public final class DockerExecSession: @unchecked Sendable {
        public static let defaultShell = "sh"

        private let lock = NSLock()
        private let launcher: any ExecPTYLaunching
        private let dockerExecutable: String
        private var state: DockerExecSessionState = .idle
        private var child: (any ExecPTYHandling)?
        private var didExit = false
        private var exitCode: Int32?
        private var exitReporter: (@Sendable (Int32) -> Void)?

        /// `dockerExecutable` is injectable for tests; production resolves it
        /// through `DockerEngine`.
        public init(
            launcher: any ExecPTYLaunching = LiveExecPTYLauncher(),
            dockerExecutable: String? = nil,
        ) throws {
            self.launcher = launcher
            if let dockerExecutable {
                self.dockerExecutable = dockerExecutable
            } else {
                self.dockerExecutable = try DockerEngine.dockerURL().path
            }
        }

        public var currentState: DockerExecSessionState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        public var lastExitCode: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return exitCode
        }

        /// Compose the docker argv. `execv`-ed directly — no host shell, so no
        /// quoting hazard — but the charset gate still rejects flag smuggling.
        public static func execArguments(container: String, shell: String) -> [String]? {
            guard DockerExecRequest.isSafeExecutableName(container),
                  DockerExecRequest.isSafeExecutableName(shell)
            else { return nil }
            return ["exec", "-it", container, shell]
        }

        /// Spawn the child. `onData` fires from the PTY read loop; `onExit`
        /// fires exactly once when the child is reaped.
        public func start(
            _ request: DockerExecRequest,
            onData: @escaping @Sendable ([UInt8]) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void,
        ) throws {
            guard let arguments = Self.execArguments(
                container: request.container,
                shell: request.shell,
            )
            else {
                throw BarkVisorError.badRequest("Invalid exec target")
            }
            lock.lock()
            guard state == .idle else {
                lock.unlock()
                throw BarkVisorError.badRequest("Exec session already started")
            }
            state = .running
            exitReporter = onExit
            lock.unlock()

            do {
                let child = try launcher.launch(
                    executable: dockerExecutable,
                    arguments: arguments,
                    onData: onData,
                    onExit: { [weak self] code in self?.deliverExit(code) },
                )
                child.resize(cols: request.cols, rows: request.rows)
                lock.lock()
                self.child = child
                lock.unlock()
            } catch {
                lock.lock()
                state = .exited
                didExit = true
                let reporter = exitReporter
                exitReporter = nil
                lock.unlock()
                reporter?(Int32.min)
                throw error
            }
        }

        public func write(_ bytes: [UInt8]) {
            lock.lock()
            let child = self.child
            let live = state == .running
            lock.unlock()
            guard live else { return }
            child?.write(bytes)
        }

        public func resize(cols: Int, rows: Int) {
            lock.lock()
            let child = self.child
            let live = state == .running
            lock.unlock()
            guard live else { return }
            child?.resize(cols: max(1, cols), rows: max(1, rows))
        }

        /// Kill + reap. Idempotent; safe to call after exit (WebSocket close).
        public func terminate() {
            lock.lock()
            let child = self.child
            lock.unlock()
            child?.terminate()
        }

        private func deliverExit(_ code: Int32) {
            lock.lock()
            guard !didExit else {
                lock.unlock()
                return
            }
            didExit = true
            state = .exited
            exitCode = code
            let reporter = exitReporter
            exitReporter = nil
            lock.unlock()
            reporter?(code)
        }
    }
#endif
