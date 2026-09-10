import Foundation
@testable import BarkVisorCore

enum ComposeTestIsolation {
    static func installFailFast() {
        ComposeRuntime.runner = FailFastComposeRunner()
        DockerCLI.runner = FailFastDockerRunner()
        DockerInspect.jsonForContainers = { _ in Data("[]".utf8) }
    }
}

enum ComposeSerialGate {
    private static let tickets = ComposeSerialTickets()

    static func acquire() async {
        await tickets.acquire()
    }

    static func release() async {
        await tickets.release()
    }

    static func run<T>(
        install: () -> Void,
        operation: () async throws -> T,
    ) async rethrows -> T {
        await tickets.acquire()
        install()
        do {
            let result = try await operation()
            ComposeTestIsolation.installFailFast()
            await tickets.release()
            return result
        } catch {
            ComposeTestIsolation.installFailFast()
            await tickets.release()
            throw error
        }
    }
}

private actor ComposeSerialTickets {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
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
