import Foundation

/// Drops repeating stderr signatures (SQLITE_FULL, leftover XPC invalidation).
///
/// `shouldRateLimit` is true when this copy should be suppressed (already
/// emitted within `interval`). The first call for a signature returns false.
public final class LogNoiseWindow: @unchecked Sendable {
    public static let shared = LogNoiseWindow()

    private let lock = NSLock()
    private var lastAllowed: [String: Date] = [:]

    public init() {}

    public func shouldRateLimit(
        signature: String,
        now: Date,
        interval: TimeInterval,
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastAllowed[signature], now.timeIntervalSince(last) < interval {
            return true
        }
        lastAllowed[signature] = now
        return false
    }
}

public enum LogNoise {
    public static let xpcInvalidationSignature = "xpc.connection-invalidated"
    public static let sqliteFullSignature = "sqlite.full"
    public static let defaultInterval: TimeInterval = 3_600

    /// True when this signature should be dropped (already logged within `interval`).
    public static func shouldRateLimit(
        signature: String,
        now: Date = Date(),
        interval: TimeInterval = defaultInterval,
        store: LogNoiseWindow = .shared,
    ) -> Bool {
        store.shouldRateLimit(signature: signature, now: now, interval: interval)
    }
}
