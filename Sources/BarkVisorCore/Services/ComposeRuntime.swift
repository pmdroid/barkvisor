import Foundation

public protocol ComposeCommandRunning: Sendable {
    func run(
        arguments: [String],
        projectDirectory: URL,
        timeout: TimeInterval,
    ) throws -> CommandResult
}

public struct LiveComposeCommandRunner: ComposeCommandRunning {
    public init() {}

    public func run(
        arguments: [String],
        projectDirectory: URL,
        timeout: TimeInterval,
    ) throws -> CommandResult {
        let docker = try DockerEngine.dockerURL()
        return try PlatformProcess.run(
            executable: docker,
            arguments: ["compose"] + arguments,
            timeout: timeout,
            currentDirectory: projectDirectory,
        )
    }
}

public enum ComposeRuntime {
    public nonisolated(unsafe) static var runner: any ComposeCommandRunning = LiveComposeCommandRunner()

    public static func projectDirectory(id: String, dataDir: URL = Config.dataDir) -> URL {
        dataDir.appendingPathComponent("workloads", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    public static func composeProjectName(id: String) -> String {
        let compact = id.replacingOccurrences(of: "-", with: "")
        let short = compact.prefix(8)
        return "barkvisor-\(short)"
    }

    public static func writeProject(
        id: String,
        yaml: String,
        env: [String: String]?,
        dataDir: URL = Config.dataDir,
    ) throws -> URL {
        if let env {
            for key in env.keys {
                try requireEnvKey(key)
            }
        }
        let dir = projectDirectory(id: id, dataDir: dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let volumes = dir.appendingPathComponent("volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        let composeURL = dir.appendingPathComponent("compose.yml")
        try yaml.write(to: composeURL, atomically: true, encoding: .utf8)
        let envURL = dir.appendingPathComponent(".env")
        if let env, !env.isEmpty {
            let body = env.keys.sorted().map { key in
                "\(key)=\(envValue(env[key] ?? ""))"
            }.joined(separator: "\n") + "\n"
            try body.write(to: envURL, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: envURL.path) {
            try FileManager.default.removeItem(at: envURL)
        }
        return dir
    }

    public static func removeProject(id: String, dataDir: URL = Config.dataDir) {
        let dir = projectDirectory(id: id, dataDir: dataDir)
        try? FileManager.default.removeItem(at: dir)
    }

    public static func up(id: String, project: String, dataDir: URL = Config.dataDir) throws {
        try invoke(id: id, project: project, command: ["up", "-d"], timeout: 180, dataDir: dataDir)
    }

    public static func stop(id: String, project: String, dataDir: URL = Config.dataDir) throws {
        try invoke(id: id, project: project, command: ["stop"], timeout: 60, dataDir: dataDir)
    }

    public static func start(id: String, project: String, dataDir: URL = Config.dataDir) throws {
        try invoke(id: id, project: project, command: ["start"], timeout: 60, dataDir: dataDir)
    }

    public static func down(id: String, project: String, dataDir: URL = Config.dataDir) throws {
        try invoke(id: id, project: project, command: ["down", "-v"], timeout: 90, dataDir: dataDir)
    }

    public static func psState(id: String, project: String, dataDir: URL = Config.dataDir) throws -> String {
        let result = try invokeResult(
            id: id,
            project: project,
            command: ["ps", "--format", "json"],
            timeout: 30,
            dataDir: dataDir,
        )
        return decodeComposeState(result.stdoutString)
    }

    public static func listLabeledStates() -> [String: String]? {
        guard let docker = try? DockerEngine.dockerURL() else { return nil }
        guard let result = try? PlatformProcess.run(
            executable: docker,
            arguments: [
                "ps", "-a",
                "--filter", "label=\(ComposeAllowlist.workloadLabelKey)",
                "--format",
                "{{.Label \"\(ComposeAllowlist.workloadLabelKey)\"}}\t{{.State}}",
            ],
            timeout: 20,
        ), result.succeeded else { return nil }
        var states: [String: String] = [:]
        for line in result.stdoutString.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let state = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if id.isEmpty { continue }
            if state.contains("running") {
                states[id] = "running"
            } else if states[id] != "running" {
                states[id] = "stopped"
            }
        }
        return states
    }

    @discardableResult
    private static func invoke(
        id: String,
        project: String,
        command: [String],
        timeout: TimeInterval,
        dataDir: URL,
    ) throws -> CommandResult {
        let result = try invokeResult(
            id: id, project: project, command: command, timeout: timeout, dataDir: dataDir,
        )
        if result.succeeded { return result }
        let err = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = [err, out].first { !$0.isEmpty } ?? "docker compose \(command.joined(separator: " ")) failed"
        throw BarkVisorError.internalError(message)
    }

    private static func invokeResult(
        id: String,
        project: String,
        command: [String],
        timeout: TimeInterval,
        dataDir: URL,
    ) throws -> CommandResult {
        let dir = projectDirectory(id: id, dataDir: dataDir)
        let file = dir.appendingPathComponent("compose.yml").path
        let arguments = [
            "-p", project,
            "-f", file,
            "--project-directory", dir.path,
        ] + command
        return try runner.run(arguments: arguments, projectDirectory: dir, timeout: timeout)
    }

    static func decodeComposeState(_ stdout: String) -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "stopped" }
        var blobs: [Any] = []
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let array = json as? [Any] {
                blobs = array
            } else {
                blobs = [json]
            }
        } else {
            for line in trimmed.split(whereSeparator: \.isNewline) {
                guard let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                blobs.append(json)
            }
        }
        if blobs.isEmpty { return "stopped" }
        var running = false
        var any = false
        for blob in blobs {
            guard let object = blob as? [String: Any] else { continue }
            any = true
            let state = (
                (object["State"] as? String) ?? (object["status"] as? String) ?? "",
            ).lowercased()
            if state.contains("running") { running = true }
        }
        if running { return "running" }
        if any { return "stopped" }
        return "stopped"
    }

    static func requireEnvKey(_ key: String) throws {
        guard let first = key.unicodeScalars.first else {
            throw BarkVisorError.badRequest("invalid compose env key")
        }
        let firstAllowed = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        guard firstAllowed.contains(first) else {
            throw BarkVisorError.badRequest("invalid compose env key")
        }
        let rest = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if !key.unicodeScalars.allSatisfy({ rest.contains($0) }) {
            throw BarkVisorError.badRequest("invalid compose env key")
        }
        let upper = key.uppercased()
        if upper.hasPrefix("COMPOSE_") || upper.hasPrefix("DOCKER_") {
            throw BarkVisorError.badRequest("invalid compose env key")
        }
    }

    private static func envValue(_ raw: String) -> String {
        if raw.contains(where: { $0 == "\n" || $0 == "#" || $0 == " " }) {
            let escaped = raw.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return raw
    }
}
