#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation

/// Console-local Home join (PAS-180 / PAS-176 slice C).
///
/// Posts the pairing offer to this Device's host API. Join is not proxied
/// through Home (`HomeDeviceProxy.rejectConsoleLocalOnly` stays in force).
public enum LocalPairingJoin {
    public static let path = "/api/pairing/join"
    public static let environmentKey = "BARKVISOR_JOIN_CODE"

    public static func localURL(port: Int = Config.port) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        guard let url = components.url else {
            throw PairingError.invalidPayload("Invalid local join URL")
        }
        return url
    }

    public static func request(offer: String) throws -> PairingJoinRequest {
        let trimmed = offer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PairingError.invalidPayload("Pairing offer is required")
        }
        return PairingJoinRequest(qrPayload: trimmed)
    }

    /// First-boot env join only. After setup or an existing receipt, ignore
    /// `BARKVISOR_JOIN_CODE` so a later restart does not re-pair.
    public static func firstBootOffer(
        environment: [String: String],
        setupComplete: Bool,
        alreadyPaired: Bool,
    ) -> String? {
        guard !setupComplete, !alreadyPaired else { return nil }
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    public static func post(
        offer: String,
        port: Int = Config.port,
        client: any PairingHTTPClient,
    ) async throws -> PairingJoinResponse {
        let url = try localURL(port: port)
        let body = try JSONEncoder().encode(request(offer: offer))
        let http: PairingHTTPResponse
        do {
            http = try await client.postJSON(url: url, body: body)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to reach this Device at \(url.absoluteString): \(error.localizedDescription)",
            )
        }
        if (200 ..< 300).contains(http.status) {
            do {
                return try JSONDecoder().decode(PairingJoinResponse.self, from: http.body)
            } catch {
                throw PairingError.invalidPayload("Local join returned an invalid response")
            }
        }
        let reason = decodeReason(http.body) ?? "HTTP \(http.status)"
        throw PairingError.redeemFailed(status: http.status, reason: reason)
    }

    private static func decodeReason(_ body: Data) -> String? {
        struct Envelope: Decodable {
            var reason: String?
        }
        return try? JSONDecoder().decode(Envelope.self, from: body).reason
    }
}
