import Foundation

/// One container of a Workload's compose project (issue #609 — Terminal tab
/// service picker and exec-target validation).
public struct WorkloadContainer: Codable, Sendable, Equatable {
    public var service: String
    public var name: String
    public var state: String

    public init(service: String, name: String, state: String) {
        self.service = service
        self.name = name
        self.state = state
    }
}

/// Maps a Workload to its `docker exec` targets and validates that a
/// requested service actually belongs to the Workload's compose project —
/// the daemon must never exec into an arbitrary container by user name.
public enum ContainerResolver {
    /// `docker compose ps --format json` for this project. Empty when the
    /// project has no containers; failures surface as errors so the UI can
    /// distinguish "no containers" from "docker broken".
    public static func listContainers(
        id: String,
        project: String,
        dataDir: URL = Config.dataDir,
    ) throws -> [WorkloadContainer] {
        let dir = ComposeRuntime.projectDirectory(id: id, dataDir: dataDir)
        let file = dir.appendingPathComponent("compose.yml").path
        let arguments = [
            "-p", project,
            "-f", file,
            "--project-directory", dir.path,
            "ps", "--format", "json",
        ]
        let result = try ComposeRuntime.runner.run(
            arguments: arguments,
            projectDirectory: dir,
            timeout: 30,
        )
        guard result.succeeded else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BarkVisorError.internalError(
                message.isEmpty ? "docker compose ps failed" : message,
            )
        }
        return decodeComposePS(result.stdoutString)
    }

    /// Accepts the three shapes docker emits: a JSON array, one JSON object,
    /// or newline-delimited JSON (varies by compose version / tty).
    public static func decodeComposePS(_ stdout: String) -> [WorkloadContainer] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var blobs: [Any] = []
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let array = json as? [Any] {
                blobs = array
            } else if json is [String: Any] {
                blobs = [json]
            }
        }
        if blobs.isEmpty {
            for line in trimmed.split(whereSeparator: \.isNewline) {
                guard let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      json is [String: Any]
                else { continue }
                blobs.append(json)
            }
        }
        var containers: [WorkloadContainer] = []
        for blob in blobs {
            guard let object = blob as? [String: Any] else { continue }
            guard let service = stringValue(object["Service"]) ?? stringValue(object["service"]),
                  let name = stringValue(object["Name"]) ?? stringValue(object["name"])
            else { continue }
            let state = (stringValue(object["State"]) ?? stringValue(object["state"]) ?? "")
                .lowercased()
            containers.append(WorkloadContainer(service: service, name: name, state: state))
        }
        return containers
    }

    /// The exec target for `service` inside this project. Never matches a
    /// container outside the project list — that gate is the whole point.
    public static func resolve(
        containers: [WorkloadContainer],
        service: String,
    ) throws -> WorkloadContainer {
        guard isValidServiceName(service) else {
            throw BarkVisorError.badRequest("Invalid service name")
        }
        guard let match = containers.first(where: { $0.service == service }) else {
            throw BarkVisorError.badRequest("Service is not part of this workload")
        }
        guard DockerExecRequest.isSafeExecutableName(match.name) else {
            throw BarkVisorError.badRequest("Container name is not exec-safe")
        }
        return match
    }

    /// Compose service-name grammar (restricted charset; also the picker key
    /// echoed back in the `service=` query, which must survive Home hops).
    public static func isValidServiceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix("-") else { return false }
        guard let first = name.unicodeScalars.first else { return false }
        let letters = CharacterSet.letters.union(CharacterSet.decimalDigits)
        let rest = letters.union(CharacterSet(charactersIn: "-_."))
        guard letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { rest.contains($0) }
    }

    private static func stringValue(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
