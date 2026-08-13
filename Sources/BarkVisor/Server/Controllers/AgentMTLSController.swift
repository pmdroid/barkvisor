import BarkVisorCore
import Vapor

/// Agent-plane identity (PAS-76). Bound only on the mTLS listener (7778).
struct AgentMTLSController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "agent", "whoami", use: whoami)
    }

    @Sendable
    func whoami(req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }
}
