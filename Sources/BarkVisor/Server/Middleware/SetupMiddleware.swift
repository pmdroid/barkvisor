import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// Blocks all non-setup API routes when no admin user with a password exists.
/// Static assets and the setup API are always allowed so the web-based setup wizard works.
final class SetupMiddleware: AsyncMiddleware, @unchecked Sendable {
    private let lock = NSLock()
    private var _setupComplete: Bool
    private let dbPool: DatabasePool

    var isSetupComplete: Bool {
        lock.withLock { _setupComplete }
    }

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        // Check if any user has a password set
        let hasAdmin =
            (try? dbPool.read { db in
                try User.filter(User.Columns.password != "").fetchCount(db) > 0
            }) ?? false
        self._setupComplete = hasAdmin
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if isSetupComplete {
            return try await next.respond(to: request)
        }

        let path = request.url.path

        // Always allow: static assets, health check, setup endpoints
        if !path.hasPrefix("/api/") || path.hasPrefix("/api/setup") || path.hasPrefix("/api/health") {
            return try await next.respond(to: request)
        }

        // All other API routes blocked until setup completes
        throw Abort(.serviceUnavailable, reason: "setup_required")
    }

    /// Called by SetupController after admin user is created.
    func markComplete() {
        lock.withLock { _setupComplete = true }
    }
}
