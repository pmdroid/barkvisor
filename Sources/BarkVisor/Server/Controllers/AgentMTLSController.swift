import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// Agent-plane identity (PAS-76) and shared-login copy (PAS-283).
/// Bound only on the mTLS listener (7778). Identity is rate-limited and
/// granted only to the Device that just redeemed, until the offer expires.
struct AgentMTLSController: RouteCollection {
    var dataDir: URL?
    var database: DatabasePool?
    var identityRateLimit: RateLimitMiddleware

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "agent", "whoami", use: whoami)
        routes.grouped(identityRateLimit).get("api", "agent", "pairing", "identity", use: identity)
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
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        guard let dataDir else {
            throw Abort(.serviceUnavailable, reason: "Home identity is unavailable")
        }
        do {
            try PairingService.authorizeIdentityRead(
                dataDir: dataDir,
                hostId: peer.hostId,
                fingerprint: peer.fingerprint,
            )
        } catch let error as PairingError {
            audit(
                action: "pairing.identity.denied",
                peer: peer,
                detail: error.localizedDescription,
            )
            throw Abort(.unauthorized, reason: error.localizedDescription)
        }
        do {
            let identity = try PairingService.sharedIdentity(dataDir: dataDir, db: database)
            audit(action: "pairing.identity", peer: peer)
            return identity
        } catch {
            throw Abort(
                .serviceUnavailable,
                reason: "Unable to load Home identity: \(error.localizedDescription)",
            )
        }
    }

    private func audit(action: String, peer: AgentPeerIdentity, detail: String? = nil) {
        guard let database else { return }
        AuditService.log(
            action: action,
            resourceType: "device",
            resourceId: peer.hostId,
            detail: detail,
            authMethod: "mtls",
            db: database,
        )
    }
}
