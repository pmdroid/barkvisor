import Foundation

/// Phone sign-in URI. Distinct from pairing (`barkvisor://pair/v1`).
enum LoginURI {
    static let scheme = "barkvisor"
    static let hostName = "login"
    static let path = "/v1"
    static let pairingHost = "pair"

    struct Payload: Equatable {
        var code: String
        var host: String
        var port: Int

        var deviceURL: String {
            "http://\(host):\(port)"
        }
    }

    static func parse(_ raw: String) throws -> Payload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            throw APIError.http(status: 400, reason: "Not a sign-in QR")
        }
        guard components.scheme == scheme else {
            throw APIError.http(status: 400, reason: "Not a sign-in QR")
        }
        if components.host == pairingHost {
            throw APIError.http(
                status: 400,
                reason: "That QR pairs Devices. Scan a sign-in QR from Settings on the Device.",
            )
        }
        guard components.host == hostName else {
            throw APIError.http(status: 400, reason: "Not a sign-in QR")
        }
        let path = components.path.isEmpty ? Self.path : components.path
        guard path == Self.path || path == "\(Self.path)/" else {
            throw APIError.http(status: 400, reason: "Unsupported sign-in QR")
        }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        guard let code = query["code"], !code.isEmpty else {
            throw APIError.http(status: 400, reason: "Sign-in QR is missing a code")
        }
        guard let host = query["host"], isAllowedHost(host) else {
            throw APIError.http(status: 400, reason: "Sign-in QR has an invalid host")
        }
        guard let portRaw = query["port"], let port = Int(portRaw), (1 ... 65_535).contains(port) else {
            throw APIError.http(status: 400, reason: "Sign-in QR has an invalid port")
        }
        return Payload(code: code, host: host, port: port)
    }

    /// Same advertised-host allow-list as pairing (PAS-226).
    static func isAllowedHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(where: { $0 == "/" || $0 == "@" || $0 == "\\" || $0.isWhitespace }) {
            return false
        }
        if host.contains("://") { return false }
        if host == "localhost" || host.hasPrefix("localhost.") { return false }
        if host == "metadata" || host == "metadata.google.internal" || host.hasSuffix(".internal") {
            return false
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            let octets = parts.compactMap { UInt8($0) }
            guard octets.count == 4 else { return false }
            if octets == [100, 100, 100, 200] { return false }
            if octets[0] == 10 { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 172, (16 ... 31).contains(octets[1]) { return true }
            if octets[0] == 100, (64 ... 127).contains(octets[1]) { return true }
            return false
        }
        return host.contains(".")
    }
}
