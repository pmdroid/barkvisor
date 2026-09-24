import Foundation

public enum DockerEventEnvironment {
    public static func make(
        identity: DockerRuntimeIdentity,
        base: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String: String] {
        var env = base
        let dockerPath = identity.executablePath.isEmpty ? nil : identity.executablePath
        for (key, value) in DockerEngine.cliEnvironment(dockerPath: dockerPath) {
            env[key] = value
        }
        return env
    }
}

public struct LiveDockerEventSource: DockerEventProducing {
    public init() {}

    public func open(identity: DockerRuntimeIdentity) -> DockerEventSubscription {
        #if os(Windows)
            return DockerEventSubscription(
                stream: AsyncStream<DockerEventDelivery> { $0.finish() },
                cancel: {},
            )
        #else
            let cancelBox = StreamCancel()
            let stream = AsyncStream<DockerEventDelivery>(bufferingPolicy: .bufferingOldest(256)) { continuation in
                let session = DockerEventProcess()
                cancelBox.arm {
                    session.stop()
                    continuation.finish()
                }
                session.start(
                    identity: identity,
                    continuation: continuation,
                    onGap: {
                        if case .dropped = continuation.yield(.gap) {
                            continuation.finish()
                        }
                    },
                )
                continuation.onTermination = { _ in
                    session.stop()
                }
            }
            return DockerEventSubscription(stream: stream, cancel: { cancelBox.cancel() })
        #endif
    }
}

private final class StreamCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable () -> Void)?
    private var cancelled = false

    func arm(_ finish: @escaping @Sendable () -> Void) {
        lock.lock()
        self.finish = finish
        let shouldFinish = cancelled
        lock.unlock()
        if shouldFinish { finish() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = finish
        lock.unlock()
        action?()
    }
}

#if !os(Windows)
    private final class DockerEventProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var pumpThread: Thread?
        private let buffer = BoundedLineBuffer(capacity: 256)
        private let chunks = ChunkLines()

        func start(
            identity: DockerRuntimeIdentity,
            continuation: AsyncStream<DockerEventDelivery>.Continuation,
            onGap: @escaping @Sendable () -> Void,
        ) {
            let docker: URL
            do {
                docker = try DockerEngine.dockerURL()
            } catch {
                continuation.finish()
                return
            }
            let process = Process()
            process.executableURL = docker
            process.arguments = [
                "events",
                "--filter", "type=container",
                "--format", "{{json .}}",
            ]
            process.environment = DockerEventEnvironment.make(identity: identity)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            let buffer = self.buffer
            let chunks = self.chunks
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                let fed = chunks.feed(text)
                if fed.overflow {
                    buffer.markDropped()
                }
                for line in fed.lines {
                    buffer.append(line: line)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.finish()
                return
            }
            lock.lock()
            self.process = process
            lock.unlock()
            let pump = Thread {
                while self.keepPumping(process) {
                    if buffer.takeDropped() {
                        onGap()
                    }
                    if let line = buffer.waitLine(for: .milliseconds(200)) {
                        if case .dropped = continuation.yield(.line(line)) {
                            continuation.finish()
                            break
                        }
                    }
                }
                continuation.finish()
            }
            pump.start()
            lock.lock()
            self.pumpThread = pump
            lock.unlock()
        }

        private func keepPumping(_ process: Process) -> Bool {
            lock.lock()
            let running = self.process != nil
            lock.unlock()
            return running && process.isRunning
        }

        func stop() {
            lock.lock()
            let process = self.process
            self.process = nil
            self.pumpThread = nil
            lock.unlock()
            process?.terminate()
        }
    }

    private final class ChunkLines: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private let limit = 1_048_576

        func feed(_ chunk: String) -> (lines: [String], overflow: Bool) {
            lock.lock()
            defer { lock.unlock() }
            pending.append(contentsOf: chunk)
            var overflow = false
            if pending.utf8.count > limit {
                pending.removeAll(keepingCapacity: false)
                overflow = true
                return ([], overflow)
            }
            var lines: [String] = []
            while let newline = pending.firstIndex(where: \.isNewline) {
                let line = pending[..<newline]
                if !line.isEmpty {
                    lines.append(String(line))
                }
                pending = String(pending[pending.index(after: newline)...])
            }
            return (lines, overflow)
        }
    }
#endif
