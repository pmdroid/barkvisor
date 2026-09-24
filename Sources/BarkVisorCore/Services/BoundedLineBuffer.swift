import Foundation

public final class BoundedLineBuffer: @unchecked Sendable {
    public let capacity: Int
    private let condition = NSCondition()
    private var lines: [String] = []
    private var droppedFlag = false

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return lines.count
    }

    public func append(line: String) {
        condition.lock()
        if lines.count >= capacity {
            droppedFlag = true
            condition.signal()
            condition.unlock()
            return
        }
        lines.append(line)
        condition.signal()
        condition.unlock()
    }

    public func markDropped() {
        condition.lock()
        droppedFlag = true
        condition.signal()
        condition.unlock()
    }

    public func takeDropped() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let dropped = droppedFlag
        droppedFlag = false
        return dropped
    }

    public func waitLine(for timeout: Duration) -> String? {
        condition.lock()
        defer { condition.unlock() }
        let seconds = Self.seconds(timeout)
        let deadline = Date().addingTimeInterval(seconds)
        while lines.isEmpty {
            if !condition.wait(until: deadline) {
                return nil
            }
        }
        return lines.removeFirst()
    }

    private static func seconds(_ timeout: Duration) -> TimeInterval {
        let parts = timeout.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
