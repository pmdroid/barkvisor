import Foundation
@testable import BarkVisorCore

enum DockerInspectTestGate {
    private static let tickets = DockerInspectTestTickets()

    static func withStub<T>(
        _ stub: @escaping @Sendable ([String]) throws -> Data,
        operation: () async throws -> T,
    ) async throws -> T {
        await tickets.acquire()
        let previous = DockerInspect.jsonForContainers
        DockerInspect.jsonForContainers = stub
        do {
            let result = try await operation()
            DockerInspect.jsonForContainers = previous
            await tickets.release()
            return result
        } catch {
            DockerInspect.jsonForContainers = previous
            await tickets.release()
            throw error
        }
    }
}

private actor DockerInspectTestTickets {
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
