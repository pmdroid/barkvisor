import Foundation

public protocol DockerCommandRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public struct LiveDockerCommandRunner: DockerCommandRunning {
    public init() {}

    public func run(arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let docker = try DockerEngine.dockerURL()
        return try PlatformProcess.run(
            executable: docker,
            arguments: arguments,
            timeout: timeout,
        )
    }
}

public enum DockerCLI {
    public nonisolated(unsafe) static var runner: any DockerCommandRunning = LiveDockerCommandRunner()

    public static func run(arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runner.run(arguments: arguments, timeout: timeout)
    }
}
