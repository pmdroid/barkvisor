import BarkVisorCore
import Foundation
import Vapor

extension HomeMembershipSnapshot: Content {}
extension AgentCertificateRenewResponse: Content {}

/// Agent-plane identity (PAS-76). Bound only on the mTLS listener (7778).
struct AgentMTLSController: RouteCollection {
    var dataDir: URL?
    var hostId: String?

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "agent", "whoami", use: whoami)
        routes.get("api", "agent", "membership", use: membership)
        routes.post("api", "agent", "certificates", "renew", use: renew)
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

    /// Replace the leaf this member presents (issue #740).
    ///
    /// The client certificate is the credential: the presented leaf comes from
    /// the handshake, and the CSR must carry that leaf's key, so a renewal can
    /// only ever extend the same Device identity. A Home that predates this
    /// route does not register it and answers 404, which the member treats as
    /// "this Home cannot renew" and keeps its existing certificate.
    @Sendable
    func renew(req: Vapor.Request) throws -> AgentCertificateRenewResponse {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        guard let presented = req.mtlsPeerCertificatePEM else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        guard let dataDir, let hostId else {
            throw Abort(.serviceUnavailable, reason: "Certificate renewal is not available")
        }
        let request: AgentCertificateRenewRequest
        do {
            request = try req.content.decode(AgentCertificateRenewRequest.self)
        } catch {
            throw BarkVisorError.badRequest("Invalid certificate renewal request")
        }
        do {
            return try HomeCertificateRenewal.issueReplacement(
                dataDir: dataDir,
                issuerHostId: hostId,
                peer: peer,
                presentedCertificatePEM: presented,
                request: request,
            )
        } catch let error as CertificateRenewalError {
            throw error.barkVisorError
        } catch let error as HomeCAError {
            throw BarkVisorError.internalError(
                error.errorDescription ?? "Unable to issue a replacement certificate",
            )
        }
    }

    @Sendable
    func whoami(req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }
}
