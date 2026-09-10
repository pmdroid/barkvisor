import Foundation

public struct DockerEngineSnapshot: Sendable, Equatable {
    public var os: String
    public var dockerPath: String?
    public var dockerVersion: String?
    public var daemonRunning: Bool
    public var composeVersion: String?
    public var composeOK: Bool
    public var composePlugin: Bool
    public var composePath: String?

    public init(
        os: String,
        dockerPath: String? = nil,
        dockerVersion: String? = nil,
        daemonRunning: Bool = false,
        composeVersion: String? = nil,
        composeOK: Bool = false,
        composePlugin: Bool = false,
        composePath: String? = nil,
    ) {
        self.os = os
        self.dockerPath = dockerPath
        self.dockerVersion = dockerVersion
        self.daemonRunning = daemonRunning
        self.composeVersion = composeVersion
        self.composeOK = composeOK
        self.composePlugin = composePlugin
        self.composePath = composePath
    }

    public var isWindows: Bool {
        os.caseInsensitiveCompare("Windows") == .orderedSame
    }

    public var isMacOS: Bool {
        os.caseInsensitiveCompare("macOS") == .orderedSame
            || os.caseInsensitiveCompare("Darwin") == .orderedSame
    }

    public var capabilitySupported: Bool {
        !isWindows && composeOK
    }
}

public enum DockerEngine {
    public nonisolated(unsafe) static var snapshotProvider: @Sendable () -> DockerEngineSnapshot = {
        liveSnapshot()
    }

    public static func snapshot() -> DockerEngineSnapshot {
        snapshotProvider()
    }

    public static func liveSnapshot() -> DockerEngineSnapshot {
        let os = PlatformHost.platformName
        if os.caseInsensitiveCompare("Windows") == .orderedSame {
            return DockerEngineSnapshot(os: os)
        }
        guard let docker = which("docker") else {
            return DockerEngineSnapshot(os: os)
        }
        let cliEnv = cliEnvironment(dockerPath: docker.path)
        let version = run(docker, ["version", "--format", "{{.Client.Version}}"], timeout: 5)
            ?? run(docker, ["--version"], timeout: 5)
        let daemon = run(docker, ["info"], timeout: 8, extraEnvironment: cliEnv) != nil
        let pluginOut = run(docker, ["compose", "version"], timeout: 8, extraEnvironment: cliEnv)
        if let pluginOut, isComposeV2(pluginOut) {
            return DockerEngineSnapshot(
                os: os,
                dockerPath: docker.path,
                dockerVersion: version?.trimmingCharacters(in: .whitespacesAndNewlines),
                daemonRunning: daemon,
                composeVersion: pluginOut.trimmingCharacters(in: .whitespacesAndNewlines),
                composeOK: true,
                composePlugin: true,
            )
        }
        var composePath: String?
        var composeVersion: String?
        var composeOK = false
        if let standalone = resolveComposePath(dockerPath: docker.path) {
            let standaloneURL = URL(fileURLWithPath: standalone)
            if let standaloneOut = run(standaloneURL, ["version"], timeout: 8), isComposeV2(standaloneOut) {
                composePath = standalone
                composeVersion = standaloneOut.trimmingCharacters(in: .whitespacesAndNewlines)
                composeOK = true
            }
        }
        return DockerEngineSnapshot(
            os: os,
            dockerPath: docker.path,
            dockerVersion: version?.trimmingCharacters(in: .whitespacesAndNewlines),
            daemonRunning: daemon,
            composeVersion: composeVersion,
            composeOK: composeOK,
            composePlugin: false,
            composePath: composePath,
        )
    }

    public static func capability(from snapshot: DockerEngineSnapshot = snapshot()) -> CapabilityDetail {
        if snapshot.isWindows {
            return CapabilityDetail(
                code: .dockerEngine,
                supported: false,
                reason: .osUnsupported,
                remediation: "Docker apps on Windows Devices are not available yet.",
            )
        }
        if snapshot.composeOK {
            return CapabilityDetail(code: .dockerEngine, supported: true)
        }
        return CapabilityDetail(
            code: .dockerEngine,
            supported: false,
            reason: .helperMissing,
            remediation: helperRemediation(os: snapshot.os),
        )
    }

    public static func requireDeviceRuntime(snapshot: DockerEngineSnapshot = snapshot()) throws {
        if snapshot.isWindows {
            throw BarkVisorError.osUnsupported(
                "runtime: device is not supported on Windows. \(helperRemediation(os: snapshot.os))",
            )
        }
        if !snapshot.composeOK {
            throw BarkVisorError.helperMissing(helperRemediation(os: snapshot.os))
        }
    }

    public static func dockerURL(snapshot: DockerEngineSnapshot = snapshot()) throws -> URL {
        try requireDeviceRuntime(snapshot: snapshot)
        if let path = snapshot.dockerPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        throw BarkVisorError.helperMissing(helperRemediation(os: snapshot.os))
    }

    public static func composeInvocation(
        snapshot: DockerEngineSnapshot = snapshot(),
    ) throws -> (executable: URL, prefix: [String]) {
        try requireDeviceRuntime(snapshot: snapshot)
        if snapshot.composePlugin {
            return (try dockerURL(snapshot: snapshot), ["compose"])
        }
        if let path = snapshot.composePath, !path.isEmpty {
            return (URL(fileURLWithPath: path), [])
        }
        throw BarkVisorError.helperMissing(helperRemediation(os: snapshot.os))
    }

    public static func cliEnvironment(
        dataDir: URL = Config.dataDir,
        dockerPath: String? = nil,
    ) -> [String: String] {
        let config = prepareCLIConfig(dataDir: dataDir, dockerPath: dockerPath)
        return ["DOCKER_CONFIG": config.path]
    }

    public static func prepareCLIConfig(
        dataDir: URL = Config.dataDir,
        dockerPath: String? = nil,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    ) -> URL {
        let root = dataDir.appendingPathComponent("docker-cli", isDirectory: true)
        let plugins = root.appendingPathComponent("cli-plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let docker = dockerPath ?? resolveDockerPath()
        if let docker {
            if let compose = resolveComposePath(dockerPath: docker, isExecutable: isExecutable) {
                linkPlugin(named: "docker-compose", to: compose, in: plugins)
            }
            let buildx = URL(fileURLWithPath: docker)
                .deletingLastPathComponent()
                .appendingPathComponent("docker-buildx").path
            if isExecutable(buildx) {
                linkPlugin(named: "docker-buildx", to: buildx, in: plugins)
            }
        }
        return root
    }

    private static func linkPlugin(named: String, to: String, in plugins: URL) {
        let dest = plugins.appendingPathComponent(named)
        let target = URL(fileURLWithPath: to)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try? FileManager.default.createSymbolicLink(at: dest, withDestinationURL: target)
    }

    public static func helperRemediation(os: String) -> String {
        if os.caseInsensitiveCompare("macOS") == .orderedSame
            || os.caseInsensitiveCompare("Darwin") == .orderedSame {
            return "Install OrbStack (or Docker Desktop) so `docker compose` is on PATH."
        }
        return "Install Docker Engine and Compose v2 (docker-ce or docker.io plus docker-compose-v2)."
    }

    public static func candidatePaths(os: String = PlatformHost.platformName) -> [String] {
        if os.caseInsensitiveCompare("Linux") == .orderedSame {
            return [
                "/usr/bin/docker",
                "/usr/local/bin/docker",
            ]
        }
        return [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
    }

    public static func candidateComposePaths(os: String = PlatformHost.platformName) -> [String] {
        if os.caseInsensitiveCompare("Linux") == .orderedSame {
            return [
                "/usr/libexec/docker/cli-plugins/docker-compose",
                "/usr/local/lib/docker/cli-plugins/docker-compose",
                "/usr/bin/docker-compose",
                "/usr/local/bin/docker-compose",
            ]
        }
        return [
            "/usr/local/bin/docker-compose",
            "/opt/homebrew/bin/docker-compose",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker-compose",
            "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-compose",
            "/Applications/Docker.app/Contents/Resources/bin/docker-compose",
        ]
    }

    public static func resolveComposePath(
        dockerPath: String,
        os: String = PlatformHost.platformName,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    ) -> String? {
        var candidates: [String] = []
        let dockerURL = URL(fileURLWithPath: dockerPath)
        candidates.append(dockerURL.deletingLastPathComponent().appendingPathComponent("docker-compose").path)
        let resolved = dockerURL.resolvingSymlinksInPath()
        candidates.append(resolved.deletingLastPathComponent().appendingPathComponent("docker-compose").path)
        candidates.append(contentsOf: candidateComposePaths(os: os))
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if isExecutable(path) {
                return path
            }
        }
        return nil
    }

    public static func resolveDockerPath(
        os: String = PlatformHost.platformName,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        whichPath: String? = nil,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    ) -> String? {
        if let whichPath, !whichPath.isEmpty, isExecutable(whichPath) {
            return whichPath
        }
        let path = pathEnvironment ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("docker").path
            if isExecutable(candidate) {
                return candidate
            }
        }
        return candidatePaths(os: os).first(where: isExecutable)
    }

    public static func which(_ name: String) -> URL? {
        #if os(Windows)
            return nil
        #else
            var fromWhich: String?
            if let result = try? PlatformProcess.run(
                path: "/usr/bin/which",
                arguments: [name],
                timeout: 5,
            ), result.succeeded {
                let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    fromWhich = output
                }
            }
            if name == "docker" {
                if let path = resolveDockerPath(whichPath: fromWhich) {
                    return URL(fileURLWithPath: path)
                }
                return nil
            }
            if let fromWhich {
                return URL(fileURLWithPath: fromWhich)
            }
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            for dir in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        #endif
    }

    private static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval,
        extraEnvironment: [String: String]? = nil,
    ) -> String? {
        guard let result = try? PlatformProcess.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            extraEnvironment: extraEnvironment,
        ), result.succeeded else { return nil }
        let text = result.stdoutString.isEmpty ? result.stderrString : result.stdoutString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isComposeV2(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("v1.") || lower.contains("version 1.") { return false }
        return lower.contains("v2") || lower.contains("version 2") || lower.contains("docker compose")
    }
}
