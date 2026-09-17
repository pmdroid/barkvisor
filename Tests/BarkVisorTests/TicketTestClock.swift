import Foundation
@testable import BarkVisorCore

/// Ticket tests advance time explicitly, independent of CI scheduling delays.
final class TicketTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        lock.withLock { instant }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { instant = instant.addingTimeInterval(seconds) }
    }

    func makeStore() -> WebSocketTicketStore {
        WebSocketTicketStore(now: { self.now() })
    }
}
