import BarkVisorCore
import Vapor

extension HomeMembershipSnapshot: Content {}

/// Agent-plane identity (PAS-76). Bound only on the mTLS listener (7778).
struct AgentMTLSController: RouteCollection {
    var dataDir: URL?
    var hostId: String?

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "agent", "whoami", use: whoami)
        routes.get("api", "agent", "membership", use: membership)
    }

    @Sendable
    func membership(req: Vapor.Request) throws -> HomeMembershipSnapshot {
        guard req.mtlsPeer != nil else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        guard let dataDir, let hostId else {
            throw Abort(.serviceUnavailable, reason: "Membership snapshot is not available")
        }
        let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
        return try HomeMembershipAuthority(dataDir: dataDir).signedSnapshot(
            signerHostId: hostId,
            deviceCertificatePEM: material.deviceCertificatePEM,
            deviceKeyPEM: material.deviceKeyPEM,
            now: Date(),
        )
    }

    @Sendable
    func whoami(req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }
}
