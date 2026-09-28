import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public struct DockerFileStamp: Equatable, Sendable {
    public var modified: Int64
    public var size: Int64
    public var inode: UInt64

    public init(modified: Int64, size: Int64, inode: UInt64) {
        self.modified = modified
        self.size = size
        self.inode = inode
    }

    public static func at(_ path: String) -> DockerFileStamp? {
        #if os(Windows)
            return nil
        #else
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            let modified = stampModified(info)
            return DockerFileStamp(
                modified: modified,
                size: Int64(info.st_size),
                inode: UInt64(info.st_ino),
            )
        #endif
    }
}

#if !os(Windows)
    private func stampModified(_ info: stat) -> Int64 {
        #if os(Linux)
            Int64(info.st_mtim.tv_sec)
        #elseif os(macOS)
            Int64(info.st_mtimespec.tv_sec)
        #else
            0
        #endif
    }
#endif

public struct DockerRuntimeIdentity: Equatable, Sendable {
    public var executablePath: String
    public var executableStamp: DockerFileStamp?
    public var contextName: String
    public var endpoint: String
    public var socketPath: String?
    public var socketStamp: DockerFileStamp?

    public init(
        executablePath: String,
        executableStamp: DockerFileStamp?,
        contextName: String,
        endpoint: String,
        socketPath: String?,
        socketStamp: DockerFileStamp?,
    ) {
        self.executablePath = executablePath
        self.executableStamp = executableStamp
        self.contextName = contextName
        self.endpoint = endpoint
        self.socketPath = socketPath
        self.socketStamp = socketStamp
    }

    public static func detectFromEnvironment() -> DockerRuntimeIdentity {
        detect(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            readText: { try? String(contentsOfFile: $0, encoding: .utf8) },
            stamp: DockerFileStamp.at,
            resolveExecutable: { DockerEngine.resolveDockerPath(pathEnvironment: $0) },
        )
    }

    public static func detect(
        environment: [String: String],
        home: String,
        readText: (String) -> String?,
        stamp: (String) -> DockerFileStamp?,
        resolveExecutable: (String) -> String?,
    ) -> DockerRuntimeIdentity {
        let configDir = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".docker").path
        let configText = readText(URL(fileURLWithPath: configDir).appendingPathComponent("config.json").path)
        let context = environment["DOCKER_CONTEXT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? contextName(in: configText)
        let endpoint = environment["DOCKER_HOST"].flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultEndpoint(context: context)
        let socketPath = unixSocketPath(endpoint)
        let executable = resolveExecutable(environment["PATH"] ?? "") ?? ""
        return DockerRuntimeIdentity(
            executablePath: executable,
            executableStamp: executable.isEmpty ? nil : stamp(executable),
            contextName: context,
            endpoint: endpoint,
            socketPath: socketPath,
            socketStamp: socketPath.flatMap(stamp),
        )
    }

    static func contextName(in configText: String?) -> String {
        guard let configText,
              let data = configText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["currentContext"] as? String,
              !name.isEmpty
        else { return "default" }
        return name
    }

    static func defaultEndpoint(context: String) -> String {
        if context.isEmpty || context == "default" {
            return "unix:///var/run/docker.sock"
        }
        return "context://\(context)"
    }

    static func unixSocketPath(_ endpoint: String) -> String? {
        let prefix = "unix://"
        guard endpoint.hasPrefix(prefix) else { return nil }
        let path = String(endpoint.dropFirst(prefix.count))
        return path.isEmpty ? nil : path
    }
}

public final class DockerDiscoveryCache: @unchecked Sendable {
    public static let shared = DockerDiscoveryCache()

    private let lock = NSLock()
    private var identity: DockerRuntimeIdentity?
    private var snapshot: DockerEngineSnapshot?
    private var epoch = 0
    private var resolutions = 0
    private var refreshing = false
    var scheduleRefresh: @Sendable (@escaping @Sendable () -> Void) -> Void

    public init() {
        scheduleRefresh = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    public var resolutionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resolutions
    }

    public func invalidate() {
        lock.lock()
        identity = nil
        snapshot = nil
        epoch += 1
        lock.unlock()
    }

    public func cachedSnapshot() -> DockerEngineSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func refreshOffRequest(
        detectIdentity: @escaping @Sendable () -> DockerRuntimeIdentity = {
            DockerRuntimeIdentity.detectFromEnvironment()
        },
        make: @escaping @Sendable () -> DockerEngineSnapshot = { DockerEngine.liveSnapshot() },
    ) {
        let identity = detectIdentity()
        lock.lock()
        if refreshing || (self.identity == identity && snapshot != nil) {
            lock.unlock()
            return
        }
        refreshing = true
        let schedule = scheduleRefresh
        lock.unlock()
        schedule { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pending = self.refreshing
            self.lock.unlock()
            guard pending else { return }
            _ = self.resolve(identity: identity, make: make)
            self.lock.lock()
            self.refreshing = false
            self.lock.unlock()
        }
    }

    func cancelPendingRefresh() {
        lock.lock()
        refreshing = false
        epoch += 1
        lock.unlock()
    }

    public func resolve(
        identity: DockerRuntimeIdentity,
        make: () -> DockerEngineSnapshot,
    ) -> DockerEngineSnapshot {
        lock.lock()
        if self.identity == identity, let snapshot {
            lock.unlock()
            return snapshot
        }
        let seen = epoch
        lock.unlock()
        let resolved = make()
        lock.lock()
        if epoch == seen {
            self.identity = identity
            snapshot = resolved
            resolutions += 1
        }
        let stored = snapshot ?? resolved
        lock.unlock()
        return stored
    }

    public func productionSnapshot() -> DockerEngineSnapshot {
        resolve(identity: DockerRuntimeIdentity.detectFromEnvironment()) {
            DockerEngine.liveSnapshot()
        }
    }
}
