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

    /// Same peer check as pairing join (`SetupOrJWTMiddleware`) and the
    /// Home member proxy. The listener binds `0.0.0.0`; a LAN client must
    /// not create an admin or finish setup, including after pairing join
    /// which leaves this window open.
    static func requireConsoleLocalClient(_ peer: String?) throws {
        guard PairingPayload.isConsoleLocalClient(peer) else {
            throw Abort(.forbidden, reason: "Setup is limited to this Device")
        }
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path

        if Self.isSetupAPIPath(path) {
            let peer = request.remoteAddress?.ipAddress ?? request.peerAddress?.ipAddress
            try Self.requireConsoleLocalClient(peer)
        }

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
            // Join stays allowlisted so first-run SetupView can pair; the
            // route still requires a console-local peer (SetupOrJWTMiddleware).
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

/// Route-level twin of the SetupMiddleware path check. Pairing join does
/// not call `markComplete`, so these routes stay open until the wizard
/// finishes — but only for a loopback peer.
struct ConsoleLocalSetupMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let peer = request.remoteAddress?.ipAddress ?? request.peerAddress?.ipAddress
        try SetupMiddleware.requireConsoleLocalClient(peer)
        return try await next.respond(to: request)
    }
}
