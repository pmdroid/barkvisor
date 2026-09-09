import Foundation

public struct DockerEngineSnapshot: Sendable, Equatable {
    public var os: String
    public var dockerPath: String?
    public var dockerVersion: String?
    public var daemonRunning: Bool
    public var composeVersion: String?
    public var composeOK: Bool

    public init(
        os: String,
        dockerPath: String? = nil,
        dockerVersion: String? = nil,
        daemonRunning: Bool = false,
        composeVersion: String? = nil,
        composeOK: Bool = false,
    ) {
        self.os = os
        self.dockerPath = dockerPath
        self.dockerVersion = dockerVersion
        self.daemonRunning = daemonRunning
        self.composeVersion = composeVersion
        self.composeOK = composeOK
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
        let version = run(docker, ["version", "--format", "{{.Client.Version}}"], timeout: 5)
            ?? run(docker, ["--version"], timeout: 5)
        let daemon = run(docker, ["info"], timeout: 8) != nil
        let composeOut = run(docker, ["compose", "version"], timeout: 8)
        let composeOK = composeOut != nil && isComposeV2(composeOut ?? "")
        return DockerEngineSnapshot(
            os: os,
            dockerPath: docker.path,
            dockerVersion: version?.trimmingCharacters(in: .whitespacesAndNewlines),
            daemonRunning: daemon,
            composeVersion: composeOut?.trimmingCharacters(in: .whitespacesAndNewlines),
            composeOK: composeOK,
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

    public static func helperRemediation(os: String) -> String {
        if os.caseInsensitiveCompare("macOS") == .orderedSame
            || os.caseInsensitiveCompare("Darwin") == .orderedSame {
            return "Install OrbStack (or Docker Desktop) so `docker compose` is on PATH."
        }
        return "Install Docker Engine and Compose v2 (docker-ce or docker.io plus docker-compose-v2)."
    }

    public static func which(_ name: String) -> URL? {
        #if os(Windows)
            return nil
        #else
            if let result = try? PlatformProcess.run(
                path: "/usr/bin/which",
                arguments: [name],
                timeout: 5,
            ), result.succeeded {
                let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    return URL(fileURLWithPath: output)
                }
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

    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> String? {
        guard let result = try? PlatformProcess.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
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
