import Foundation

/// WebAuthn helpers aligned with `frontend/src/utils/webauthn.ts`.
enum PasskeySupport {
    struct Block: Equatable {
        var reason: String
        var fix: String

        var message: String { "\(reason) \(fix)" }
    }

    static func base64urlFromData(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64url(_ value: String) -> Data? {
        var b64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad != 0 { b64 += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: b64)
    }

    static func isIPHostname(_ hostname: String) -> Bool {
        if hostname.contains(":") { return true }
        let parts = hostname.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), n >= 0, n <= 255 else { return false }
            return part.allSatisfy(\.isNumber)
        }
    }

    static func passkeyBlock(for url: URL) -> Block? {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return Block(reason: "Passkeys need a hostname.", fix: "Use a Device URL with a name, not an IP.")
        }
        if isIPHostname(host) {
            let port = url.port ?? DeviceURL.defaultPort
            return Block(
                reason: "This Device URL uses a raw IP (\(host)). Passkeys need a hostname.",
                fix: "On this Device open http://localhost:\(port). Off-LAN use MagicDNS over https.",
            )
        }
        let secure = url.scheme?.lowercased() == "https" || host == "localhost"
        if !secure {
            if host.hasSuffix(".ts.net") || host.hasSuffix(".tailscale.net") {
                let port = url.port ?? DeviceURL.defaultPort
                return Block(
                    reason: "http://\(host) is not https. Passkeys will not run here.",
                    fix: "On this Device run: tailscale serve --bg \(port). Then open https://\(host).",
                )
            }
            let port = url.port ?? DeviceURL.defaultPort
            return Block(
                reason: "This Device URL is not https or localhost.",
                fix: "Open http://localhost:\(port), or put HTTPS in front of the Device.",
            )
        }
        return nil
    }

    static func originHeader(for url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? url.absoluteString
    }

    /// Finish payload credential object matching `credentialToJSON` in the web client.
    static func assertionCredentialJSON(
        id: String,
        rawID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userHandle: Data?,
    ) -> [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": base64urlFromData(clientDataJSON),
            "authenticatorData": base64urlFromData(authenticatorData),
            "signature": base64urlFromData(signature),
        ]
        if let userHandle { response["userHandle"] = base64urlFromData(userHandle) }
        return [
            "id": id,
            "rawId": base64urlFromData(rawID),
            "type": "public-key",
            "response": response,
        ]
    }
}
