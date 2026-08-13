import Foundation

/// QR / typed-code payload for PAS-45.
///
/// Encodes as `barkvisor://pair/v1?code=…&host=…&port=…&hostId=…&fp=…`.
/// The fingerprint is out-of-band trust material so a LAN redeem cannot
/// silently swap the issuer Device certificate.
public struct PairingPayload: Sendable, Equatable {
    public static let scheme = "barkvisor"
    public static let hostName = "pair"
    public static let path = "/v1"

    public var code: String
    public var host: String?
    public var port: Int
    public var agentPort: Int
    public var hostId: String
    public var fingerprint: String

    public init(
        code: String,
        host: String?,
        port: Int,
        agentPort: Int = Config.agentPort,
        hostId: String,
        fingerprint: String,
    ) {
        self.code = PairingCode.display(code)
        self.host = host
        self.port = port
        self.agentPort = agentPort
        self.hostId = hostId
        self.fingerprint = fingerprint.lowercased()
    }

    public var uri: String {
        var items = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "agentPort", value: String(agentPort)),
            URLQueryItem(name: "hostId", value: hostId),
            URLQueryItem(name: "fp", value: fingerprint),
        ]
        if let host, !host.isEmpty {
            items.insert(URLQueryItem(name: "host", value: host), at: 1)
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.hostName
        components.path = Self.path
        components.queryItems = items
        return components.string ?? "\(Self.scheme)://\(Self.hostName)\(Self.path)"
    }

    public static func parse(_ raw: String) throws -> PairingPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            throw PairingError.invalidPayload("Not a pairing URI")
        }
        guard components.scheme == scheme else {
            throw PairingError.invalidPayload("Pairing URI must use \(scheme)://")
        }
        guard components.host == hostName else {
            throw PairingError.invalidPayload("Pairing URI host must be \(hostName)")
        }
        let path = components.path.isEmpty ? Self.path : components.path
        guard path == Self.path || path == "\(Self.path)/" else {
            throw PairingError.invalidPayload("Unsupported pairing URI version")
        }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        guard let code = query["code"], PairingCode.isValid(code) else {
            throw PairingError.invalidPayload("Pairing URI is missing a valid code")
        }
        guard let hostId = query["hostId"], !hostId.isEmpty else {
            throw PairingError.invalidPayload("Pairing URI is missing hostId")
        }
        guard let fingerprint = query["fp"], !fingerprint.isEmpty else {
            throw PairingError.invalidPayload("Pairing URI is missing fingerprint")
        }
        guard let portRaw = query["port"], let port = Int(portRaw), (1 ... 65_535).contains(port) else {
            throw PairingError.invalidPayload("Pairing URI has an invalid port")
        }
        let agentPort: Int
        if let raw = query["agentPort"] {
            guard let parsed = Int(raw), (1 ... 65_535).contains(parsed) else {
                throw PairingError.invalidPayload("Pairing URI has an invalid agentPort")
            }
            agentPort = parsed
        } else {
            agentPort = Config.agentPort
        }
        return PairingPayload(
            code: code,
            host: query["host"],
            port: port,
            agentPort: agentPort,
            hostId: hostId,
            fingerprint: fingerprint,
        )
    }

    public static func sanitizeHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        if trimmed.contains(where: { $0 == "/" || $0 == "@" || $0 == "\\" || $0.isWhitespace }) {
            return nil
        }
        if trimmed.contains("://") { return nil }
        return trimmed
    }

    public static func redeemURL(host: String, port: Int) throws -> URL {
        guard (1 ... 65_535).contains(port) else {
            throw PairingError.invalidPayload("Invalid pairing port")
        }
        guard let host = sanitizeHost(host) else {
            throw PairingError.invalidPayload("Invalid pairing host")
        }
        let wrapped = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(wrapped):\(port)/api/pairing/redeem") else {
            throw PairingError.invalidPayload("Unable to build redeem URL")
        }
        guard url.scheme == "http", url.user == nil, url.password == nil else {
            throw PairingError.invalidPayload("Redeem URL must be plain HTTP")
        }
        return url
    }
}

/// Non-loopback IPv4 addresses to advertise in a pairing QR.
public enum PairingAddresses {
    public static func advertisedIPv4(
        from interfaces: [HostInterfaceInfo] = HostInfoService.listInterfaces(),
    ) -> [String] {
        interfaces.compactMap { iface -> String? in
            let ip = iface.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty else { return nil }
            if ip == "127.0.0.1" || ip.hasPrefix("127.") { return nil }
            if ip == "0.0.0.0" { return nil }
            if ip.hasPrefix("169.254.") { return nil }
            return ip
        }
    }
}
