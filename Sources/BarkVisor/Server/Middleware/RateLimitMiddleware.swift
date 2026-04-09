import BarkVisorCore
import Foundation
import Vapor

/// In-memory per-IP rate limiter. Tracks request timestamps and rejects
/// requests that exceed `maxAttempts` within the sliding `window`.
actor RateLimitStore {
    private var attempts: [String: [Date]] = [:]
    private let maxAttempts: Int
    private let window: TimeInterval

    init(maxAttempts: Int, window: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.window = window
    }

    /// Returns seconds until the client can retry, or nil if the request is allowed.
    func check(key: String) -> TimeInterval? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)

        // Prune expired entries
        var timestamps = (attempts[key] ?? []).filter { $0 > cutoff }

        if timestamps.count >= maxAttempts, let oldestRelevant = timestamps.first {
            let retryAfter = oldestRelevant.timeIntervalSince(cutoff)
            return max(retryAfter, 1)
        }

        timestamps.append(now)
        attempts[key] = timestamps
        return nil
    }

    /// Periodic cleanup of stale keys to prevent unbounded growth.
    func prune() {
        let cutoff = Date().addingTimeInterval(-window)
        for (key, timestamps) in attempts {
            let valid = timestamps.filter { $0 > cutoff }
            if valid.isEmpty {
                attempts.removeValue(forKey: key)
            } else {
                attempts[key] = valid
            }
        }
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let store: RateLimitStore

    func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
        -> Vapor.Response {
        let key = clientIP(from: request)

        if let retryAfter = await store.check(key: key) {
            let response = Response(status: .tooManyRequests)
            response.headers.add(name: "Retry-After", value: "\(Int(retryAfter))")
            return response
        }

        return try await next.respond(to: request)
    }

    /// Extract client IP from the peer/socket address directly.
    /// Proxy headers (X-Forwarded-For, X-Real-IP) are intentionally ignored
    /// because this app is not behind a trusted reverse proxy, and trusting
    /// those headers would allow trivial rate-limit bypass via header spoofing.
    private func clientIP(from request: Vapor.Request) -> String {
        request.remoteAddress?.hostname ?? request.peerAddress?.hostname ?? "unknown"
    }
}
