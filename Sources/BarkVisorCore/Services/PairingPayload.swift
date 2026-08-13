import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

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
        let host: String?
        if let rawHost = query["host"] {
            guard let clean = sanitizeHost(rawHost) else {
                throw PairingError.invalidPayload("Pairing URI has an invalid host")
            }
            host = clean
        } else {
            host = nil
        }
        return PairingPayload(
            code: code,
            host: host,
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
        if isBlockedJoinHost(trimmed) { return nil }
        return trimmed
    }

    /// Loopback, link-local, and cloud-metadata targets are not valid
    /// pairing hosts. RFC1918 LAN addresses stay allowed.
    ///
    /// IPv4 is parsed with `inet_aton` so shorthand (`127.1`), decimal,
    /// octal, and hex encodings that normalize to loopback are rejected.
    public static func isBlockedJoinHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if isBlockedJoinHostname(host) { return true }
        if let octets = parseIPv4Octets(host) {
            return isBlockedJoinIPv4(octets)
        }
        if let addr = parseIPv6(host) {
            return isBlockedJoinIPv6(addr)
        }
        return false
    }

    /// True when any resolved address is a blocked join target.
    /// Used after the string check so a public name that rebinds to
    /// loopback, link-local, or metadata cannot be used as a redeem host.
    public static func hostResolvesToBlockedAddress(_ host: String) -> Bool {
        SSRFGuard.resolvedIPStrings(host).contains { isBlockedJoinHost($0) }
    }

    public static func redeemURL(host: String, port: Int) throws -> URL {
        guard (1 ... 65_535).contains(port) else {
            throw PairingError.invalidPayload("Invalid pairing port")
        }
        guard let host = sanitizeHost(host) else {
            throw PairingError.invalidPayload("Invalid pairing host")
        }
        if hostResolvesToBlockedAddress(host) {
            throw PairingError.invalidPayload("Pairing host resolves to a blocked address")
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

    private static func isBlockedJoinHostname(_ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("localhost.") { return true }
        if host == "metadata" || host == "metadata.google.internal" { return true }
        if host.hasSuffix(".internal") { return true }
        return false
    }

    private static func isBlockedJoinIPv4(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b) = (parts.0, parts.1)
        if a == 0 { return true }
        if a == 127 { return true }
        if a == 169, b == 254 { return true }
        return false
    }

    private static func isBlockedJoinIPv6(_ addr: in6_addr) -> Bool {
        withUnsafeBytes(of: addr) { raw in
            let bytes = Array(raw)
            guard bytes.count == 16 else { return true }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if bytes.allSatisfy({ $0 == 0 }) { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isBlockedJoinIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return true }
            if bytes[0] == 0xFD, bytes[1] == 0x00, bytes[2] == 0x0E, bytes[3] == 0xC2 {
                return true
            }
            return false
        }
    }

    private static func parseIPv4Octets(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        let canonical = String(cString: buf)
        let parts = canonical.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    private static func parseIPv6(_ host: String) -> in6_addr? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return addr
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
