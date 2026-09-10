import Foundation
import Testing
@testable import BarkVisorCore

enum ComposeTestIsolation {
    static let lock: NSLock = {
        installFailFast()
        return NSLock()
    }()

    static func installFailFast() {
        ComposeRuntime.runner = FailFastComposeRunner()
        DockerCLI.runner = FailFastDockerRunner()
        DockerInspect.jsonForContainers = { _ in Data("[]".utf8) }
    }
}

struct FailFastComposeRunner: ComposeCommandRunning {
    func run(
        arguments _: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        throw BarkVisorError.internalError("test invoked live docker compose")
    }
}

struct FailFastDockerRunner: DockerCommandRunning {
    func run(arguments _: [String], timeout _: TimeInterval) throws -> CommandResult {
        throw BarkVisorError.internalError("test invoked live docker")
    }
}

@Suite struct ComposeFailFastBootstrap {
    init() {
        ComposeTestIsolation.installFailFast()
    }

    @Test func failFastInstalled() {
        #expect(Bool(true))
    }
}
