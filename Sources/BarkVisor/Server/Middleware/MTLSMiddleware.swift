import BarkVisorCore
import NIOSSL
import Vapor
import X509

struct MTLSPeerKey: StorageKey {
    typealias Value = AgentPeerIdentity
}

extension Vapor.Request {
    var mtlsPeer: AgentPeerIdentity? {
        get { storage[MTLSPeerKey.self] }
        set { storage[MTLSPeerKey.self] = newValue }
    }
}

/// Rejects agent-plane requests that survived TLS without a trusted client cert.
///
/// The handshake already requires a cert (NIOSSL mTLS). This middleware
/// extracts the leaf, re-checks Home CA / pairwise pins, and stashes the
/// peer identity for handlers.
struct MTLSMiddleware: AsyncMiddleware {
    let homeCAPEM: String
    let pins: PeerPinStore

    func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
        -> Vapor.Response {
        guard let chain = request.peerCertificateChain else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        let leaf = chain.leaf
        let pem: String
        do {
            pem = try leaf.serializeAsPEM().pemString
        } catch {
            throw Abort(.unauthorized, reason: "Unreadable client certificate")
        }
        let loadedPins: [PeerPin]
        do {
            loadedPins = try pins.load()
        } catch {
            throw Abort(.internalServerError, reason: "Peer pin store is corrupt")
        }
        switch DeviceTrust.evaluate(leafPEM: pem, homeCAPEM: homeCAPEM, pins: loadedPins) {
        case let .accepted(hostId, source):
            let fingerprint = (try? DeviceTrust.fingerprint(pem: pem)) ?? ""
            request.mtlsPeer = AgentPeerIdentity(
                hostId: hostId,
                fingerprint: fingerprint,
                trust: source.rawValue,
            )
            return try await next.respond(to: request)
        case let .rejected(reason):
            throw Abort(.unauthorized, reason: "Untrusted client certificate (\(reason.rawValue))")
        }
    }
}
