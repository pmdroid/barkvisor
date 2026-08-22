import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// Agent-plane identity (PAS-76) and shared-login copy (PAS-283).
/// Bound only on the mTLS listener (7778).
struct AgentMTLSController: RouteCollection {
    var dataDir: URL?
    var database: DatabasePool?

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "agent", "whoami", use: whoami)
        routes.get("api", "agent", "pairing", "identity", use: identity)
    }

    @Sendable
    func whoami(req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }

    @Sendable
    func identity(req: Vapor.Request) throws -> PairingSharedIdentity {
        guard req.mtlsPeer != nil else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        guard let dataDir else {
            throw Abort(.serviceUnavailable, reason: "Home identity is unavailable")
        }
        do {
            return try PairingService.sharedIdentity(dataDir: dataDir, db: database)
        } catch {
            throw Abort(
                .serviceUnavailable,
                reason: "Unable to load Home identity: \(error.localizedDescription)",
            )
        }
    }
}
