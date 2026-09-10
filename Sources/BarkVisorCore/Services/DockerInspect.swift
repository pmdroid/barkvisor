import Foundation

public enum DockerInspect {
    public nonisolated(unsafe) static var jsonForContainers: @Sendable ([String]) throws -> Data = liveJSON

    public static func liveJSON(_ names: [String]) throws -> Data {
        if names.isEmpty { return Data("[]".utf8) }
        let docker = try DockerEngine.dockerURL()
        let result = try PlatformProcess.run(
            executable: docker,
            arguments: ["inspect"] + names,
            timeout: 20,
        )
        if result.succeeded { return result.stdout }
        let err = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = [err, out].first { !$0.isEmpty } ?? "docker inspect failed"
        throw BarkVisorError.internalError(message)
    }
}
