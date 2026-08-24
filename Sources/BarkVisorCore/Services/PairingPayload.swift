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

    /// Registry / mTLS proxy target. LAN join hosts plus loopback so a
    /// same-machine member and tests can be reached. Public, metadata,
    /// and link-local addresses stay blocked.
    ///
    /// Hostnames are resolved and pinned to an allowed LAN address
    /// (`resolvedAllowedJoinAddresses`) so a public name cannot be stored
    /// or used as an egress target. DNS failure is fail-closed.
    public static func sanitizeProxyHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        let host = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isConsoleLocalClient(host) {
            return host
        }
        guard let clean = sanitizeHost(host) else { return nil }
        do {
            let resolved = try resolvedAllowedJoinAddresses(clean)
            return pinnedJoinAddress(preferred: clean, resolved: resolved)
        } catch {
            return nil
        }
    }

    /// Join egress is private-network only: RFC1918 IPv4, CGNAT
    /// `100.64.0.0/10`, and IPv6 ULA. Loopback, link-local, cloud-metadata
    /// (`169.254.169.254`, `100.100.100.200`, `fd00:ec2::/32`), and
    /// public/WAN addresses are not valid pairing hosts.
    ///
    /// IPv4 is parsed with `inet_aton` so shorthand (`127.1`), decimal,
    /// octal, and hex encodings that normalize to loopback are rejected.
    public static func isBlockedJoinHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if isBlockedJoinHostname(host) { return true }
        if let octets = parseIPv4Octets(host) {
            return !isAllowedJoinIPv4(octets)
        }
        if let addr = parseIPv6(host) {
            return isBlockedJoinIPv6(addr)
        }
        return false
    }

    /// True when the TCP peer is this Device (loopback). Unauthenticated
    /// setup-window join stays console-local so a LAN client cannot force
    /// a rogue pairing while the server is bound to 0.0.0.0.
    public static func isConsoleLocalClient(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasPrefix("localhost.") { return true }
        if let octets = parseIPv4Octets(host) {
            return octets.0 == 127
        }
        if let addr = parseIPv6(host) {
            return isIPv6Loopback(addr)
        }
        return false
    }

    /// True when the host must not be used as a join target.
    /// Fail closed: DNS failure (empty resolution) is treated as blocked
    /// so a name that later resolves to loopback, metadata, or a public
    /// address cannot slip through at check time.
    public static func hostResolvesToBlockedAddress(_ host: String) -> Bool {
        let ips = SSRFGuard.resolvedIPStrings(host)
        if ips.isEmpty { return true }
        return ips.contains { isBlockedJoinHost($0) }
    }

    /// Resolved addresses that are safe join targets. Fails closed on DNS
    /// failure or any non-LAN address (public, loopback, link-local, metadata).
    public static func resolvedAllowedJoinAddresses(_ host: String) throws -> [String] {
        let ips = SSRFGuard.resolvedIPStrings(host)
        guard !ips.isEmpty else {
            throw PairingError.invalidPayload("Pairing host could not be resolved")
        }
        if ips.contains(where: { isBlockedJoinHost($0) }) {
            throw PairingError.invalidPayload("Pairing host resolves to a blocked address")
        }
        return ips
    }

    public static func redeemURL(host: String, port: Int) throws -> URL {
        try httpAPIURL(host: host, port: port, path: "/api/pairing/redeem")
    }

    public static func contractURL(host: String, port: Int) throws -> URL {
        try httpAPIURL(host: host, port: port, path: APIContract.contractPath)
    }

    /// Shared LAN HTTP builder for join-time `GET /api/contract` and redeem.
    public static func httpAPIURL(host: String, port: Int, path: String) throws -> URL {
        guard (1 ... 65_535).contains(port) else {
            throw PairingError.invalidPayload("Invalid pairing port")
        }
        guard path.hasPrefix("/api/") else {
            throw PairingError.invalidPayload("Pairing URL path must be under /api/")
        }
        guard let host = sanitizeHost(host) else {
            throw PairingError.invalidPayload("Invalid pairing host")
        }
        // Pin a resolved allowed IP so URLSession cannot re-resolve a
        // rebinding hostname to loopback or metadata at connect time.
        let pinned = try pinnedJoinAddress(
            preferred: host,
            resolved: resolvedAllowedJoinAddresses(host),
        )
        let wrapped = pinned.contains(":") && !pinned.hasPrefix("[") ? "[\(pinned)]" : pinned
        guard let url = URL(string: "http://\(wrapped):\(port)\(path)") else {
            throw PairingError.invalidPayload("Unable to build pairing URL")
        }
        guard url.scheme == "http", url.user == nil, url.password == nil else {
            throw PairingError.invalidPayload("Pairing URL must be plain HTTP")
        }
        return url
    }

    static func pinnedJoinAddress(preferred: String, resolved: [String]) -> String {
        let stripped = preferred.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if resolved.contains(stripped) { return stripped }
        if let v4 = resolved.first(where: { parseIPv4Octets($0) != nil }) { return v4 }
        return resolved[0]
    }

    private static func isBlockedJoinHostname(_ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("localhost.") { return true }
        if host == "metadata" || host == "metadata.google.internal" { return true }
        if host.hasSuffix(".internal") { return true }
        return false
    }

    private static func isRFC1918(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b) = (parts.0, parts.1)
        if a == 10 { return true }
        if a == 172, (16 ... 31).contains(b) { return true }
        if a == 192, b == 168 { return true }
        return false
    }

    /// Shared address space used by overlay VPNs (`100.64.0.0/10`).
    /// `100.100.100.200` (Alibaba metadata) is inside this range and is
    /// carved out by ``isAllowedJoinIPv4``.
    private static func isCGNAT(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        parts.0 == 100 && (64 ... 127).contains(parts.1)
    }

    private static func isAlibabaMetadataIPv4(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        parts == (100, 100, 100, 200)
    }

    private static func isAllowedJoinIPv4(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        if isAlibabaMetadataIPv4(parts) { return false }
        if isRFC1918(parts) { return true }
        if isCGNAT(parts) { return true }
        return false
    }

    private static func isBlockedJoinIPv6(_ addr: in6_addr) -> Bool {
        withUnsafeBytes(of: addr) { raw in
            let bytes = Array(raw)
            guard bytes.count == 16 else { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return !isAllowedJoinIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            // ULA fc00::/7, except AWS metadata fd00:ec2::/32.
            let isULA = (bytes[0] & 0xFE) == 0xFC
            if isULA {
                if bytes[0] == 0xFD, bytes[1] == 0x00, bytes[2] == 0x0E, bytes[3] == 0xC2 {
                    return true
                }
                return false
            }
            return true
        }
    }

    private static func isIPv6Loopback(_ addr: in6_addr) -> Bool {
        withUnsafeBytes(of: addr) { raw in
            let bytes = Array(raw)
            guard bytes.count == 16 else { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return bytes[12] == 127
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

/// Addresses to advertise in a pairing offer: RFC1918, IPv6 ULA, and
/// CGNAT `100.64.0.0/10`, excluding metadata. IPv4 is listed first so
/// the default pick stays a LAN IPv4 when both families are present.
public enum PairingAddresses {
    public static func advertisedIPv4(
        from interfaces: [HostInterfaceInfo] = HostInfoService.listInterfaceAddresses(),
    ) -> [String] {
        var seen = Set<String>()
        var v4: [String] = []
        var v6: [String] = []
        for iface in interfaces {
            let ip = iface.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty else { continue }
            if PairingPayload.isBlockedJoinHost(ip) { continue }
            guard seen.insert(ip).inserted else { continue }
            if ip.contains(":") {
                v6.append(ip)
            } else {
                v4.append(ip)
            }
        }
        return v4 + v6
    }

    /// Pairing/login picker: configured advertise URL, then MagicDNS / tailnet
    /// IP, then hostname, then interface addresses. Duplicates are dropped.
    public static func advertisedHosts(
        from interfaces: [HostInterfaceInfo] = HostInfoService.listInterfaceAddresses(),
        tailnet: TailnetInfo? = nil,
        advertiseUrl: String? = nil,
        hostname: String? = nil,
    ) -> [String] {
        var seen = Set<String>()
        var preferred: [String] = []
        func add(_ raw: String?) {
            guard let host = raw.flatMap(PairingPayload.sanitizeHost) else { return }
            if seen.insert(host).inserted {
                preferred.append(host)
            }
        }
        add(advertiseUrl)
        if tailnet?.available == true {
            add(tailnet?.dnsName)
            add(tailnet?.ip)
        }
        add(hostname)
        let rest = advertisedIPv4(from: interfaces).filter { seen.insert($0).inserted }
        return preferred + rest
    }
}
