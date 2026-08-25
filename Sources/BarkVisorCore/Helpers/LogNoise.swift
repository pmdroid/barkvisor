import Foundation

/// Drops repeating stderr signatures (SQLITE_FULL, leftover XPC invalidation).
///
/// `shouldRateLimit` is true when this copy should be suppressed (already
/// emitted within `interval`). The first call for a signature returns false.
public final class LogNoiseWindow: @unchecked Sendable {
    public static let shared = LogNoiseWindow()
    public static let maxSignatures = 64

    private let lock = NSLock()
    private let maxSignatures: Int
    private var lastAllowed: [String: Date] = [:]

    public init(maxSignatures: Int = LogNoiseWindow.maxSignatures) {
        self.maxSignatures = max(1, maxSignatures)
    }

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
        while lastAllowed.count > maxSignatures {
            guard let oldest = lastAllowed.min(by: { $0.value < $1.value })?.key else { break }
            lastAllowed.removeValue(forKey: oldest)
        }
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
