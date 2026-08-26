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

    /// Same path set as `HomeDeviceProxy.isConsoleLocalOnly` for setup.
    static func isSetupAPIPath(_ path: String) -> Bool {
        path == "/api/setup" || path.hasPrefix("/api/setup/")
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path

        if isSetupComplete {
            return try await next.respond(to: request)
        }

        // Always allow: static assets, health, setup wizard, and public capabilities
        // (UI needs platform flags before admin exists).
        if !path.hasPrefix("/api/")
            || Self.isSetupAPIPath(path)
            || path.hasPrefix("/api/health")
            || path == "/api/system/capabilities"
            || path == "/api/openapi.yaml"
            || path == "/api/contract"
            || path == "/api/pairing/redeem"
            || path == "/api/pairing/join" {
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
