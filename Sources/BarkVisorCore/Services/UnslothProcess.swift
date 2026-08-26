import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public protocol UnslothChildProcess: Sendable {
    func terminate()
    func killAfterGrace(_ grace: TimeInterval) async
}

public protocol UnslothProcessSpawner: Sendable {
    func spawn(executablePath: String, arguments: [String]) throws -> any UnslothChildProcess
}

public struct FoundationUnslothSpawner: UnslothProcessSpawner {
    public init() {}

    public func spawn(executablePath: String, arguments: [String]) throws -> any UnslothChildProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw BarkVisorError.processSpawnFailed(
                "Could not launch \(executablePath): \(error.localizedDescription)",
            )
        }
        return FoundationUnslothChild(process: process)
    }
}

final class FoundationUnslothChild: UnslothChildProcess, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func killAfterGrace(_ grace: TimeInterval) async {
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
