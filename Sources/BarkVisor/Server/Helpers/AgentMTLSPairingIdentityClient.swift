import BarkVisorCore
import Foundation

/// Copies Home login over the agent plane after HTTP device-trust redeem.
public struct AgentMTLSPairingIdentityClient: PairingIdentityClient {
    public init() {}

    public func fetchSharedIdentity(_ request: PairingIdentityFetch) async throws -> PairingSharedIdentity {
        let url = try HomeDeviceProxy.memberURL(
            host: request.host,
            port: request.agentPort,
            path: PairingService.identityPath,
        )
        let client = AgentMTLSClient(
            material: request.material,
            presentationCertificatePEM: request.issuedCertificatePEM,
            trustCertificatePEMs: [request.trustCertificatePEM],
        )
        let http: HomeDeviceProxyResponse
        do {
            http = try await client.send(HomeDeviceProxyRequest(method: "GET", url: url))
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.redeemFailed(
                status: 502,
                reason: "Unable to copy Home login over the agent plane: \(error.localizedDescription)",
            )
        }
        guard (200 ... 299).contains(http.status) else {
            let reason = decodeReason(http.body) ?? "Unable to copy Home login"
            throw PairingError.redeemFailed(status: http.status, reason: reason)
        }
        do {
            return try JSONDecoder().decode(PairingSharedIdentity.self, from: http.body)
        } catch {
            throw PairingError.invalidPayload("Issuer returned an invalid Home login")
        }
    }

    private func decodeReason(_ data: Data) -> String? {
        struct Envelope: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.reason
    }
}
