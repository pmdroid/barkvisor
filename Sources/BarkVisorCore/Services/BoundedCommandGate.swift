import Foundation

public enum BoundedCommandGateError: Error, Equatable {
    case timedOut
}

public actor BoundedCommandGate {
    public static let docker = BoundedCommandGate(limit: 4)

    private let limit: Int
    private var inFlight = 0

    public init(limit: Int) {
        self.limit = max(limit, 1)
    }

    public var inFlightCount: Int {
        inFlight
    }

    public func run<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () throws -> T,
    ) async throws -> T {
        try await acquire(timeout: timeout)
        do {
            let value = try await Task.detached(operation: operation).value
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while inFlight >= limit {
            if clock.now >= deadline {
                throw BoundedCommandGateError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        inFlight += 1
    }

    private func release() {
        if inFlight > 0 {
            inFlight -= 1
        }
    }
}
