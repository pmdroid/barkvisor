import Foundation

/// How a Device address can be reached (PAS-63).
///
/// Classification is by address space, not by interface name:
/// - `lan` — RFC1918 IPv4 and IPv6 unique-local (except Tailscale / metadata)
/// - `tailnet` — CGNAT `100.64.0.0/10` and Tailscale IPv6 `fd7a:115c:a1e0::/48`
/// - `loopback` / `other` — not listed as reachability addresses
public enum HostAddressScope: String, Sendable, Equatable {
    case lan
    case tailnet
    case loopback
    case other
}

/// LAN and tailnet IPs this Device currently has (PAS-63).
///
/// Loopback, link-local, public, and metadata addresses are omitted.
/// `tailnet` is the overlay used for off-LAN Home reachability (PAS-89 Tailscale).
public struct DeviceReachabilityAddresses: Codable, Sendable, Equatable {
    public var lan: [String]
    public var tailnet: [String]

    public static let empty = DeviceReachabilityAddresses(lan: [], tailnet: [])

    public init(lan: [String] = [], tailnet: [String] = []) {
        self.lan = lan
        self.tailnet = tailnet
    }

    public var isEmpty: Bool {
        lan.isEmpty && tailnet.isEmpty
    }
}

/// Collects Device IPs for LAN / tailnet reachability. Does not start a VPN.
public enum HostAddressClassifier {
    /// Tailscale unique-local prefix (`fd7a:115c:a1e0::/48`).
    private static let tailscaleULA: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]

    public static func scope(of raw: String) -> HostAddressScope {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return .other }
        if let octets = parseIPv4Octets(host) {
            return scopeIPv4(octets)
        }
        if let addr = parseIPv6(host) {
            return scopeIPv6(addr)
        }
        return .other
    }

    public static func collect(
        from interfaces: [HostInterfaceInfo] = HostInfoService.listInterfaceAddresses(),
        tailnet: TailnetInfo? = nil,
    ) -> DeviceReachabilityAddresses {
        var lanV4: [String] = []
        var lanV6: [String] = []
        var tailV4: [String] = []
        var tailV6: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard !ip.isEmpty, seen.insert(ip).inserted else { return }
            let isV6 = ip.contains(":")
            switch scope(of: ip) {
            case .lan:
                if isV6 { lanV6.append(ip) } else { lanV4.append(ip) }
            case .tailnet:
                if isV6 { tailV6.append(ip) } else { tailV4.append(ip) }
            case .loopback, .other:
                break
            }
        }

        for iface in interfaces {
            add(iface.ipAddress)
        }
        if tailnet?.available == true, let ip = tailnet?.ip {
            add(ip)
        }
        return DeviceReachabilityAddresses(
            lan: lanV4 + lanV6,
            tailnet: tailV4 + tailV6,
        )
    }

    private static func scopeIPv4(_ parts: (UInt8, UInt8, UInt8, UInt8)) -> HostAddressScope {
        let (a, b) = (parts.0, parts.1)
        if a == 127 { return .loopback }
        if a == 100, b == 100, parts.2 == 100, parts.3 == 200 { return .other }
        if a == 100, (64 ... 127).contains(b) { return .tailnet }
        if a == 10 { return .lan }
        if a == 172, (16 ... 31).contains(b) { return .lan }
        if a == 192, b == 168 { return .lan }
        return .other
    }

    private static func scopeIPv6(_ addr: in6_addr) -> HostAddressScope {
        withUnsafeBytes(of: addr) { raw in
            let bytes = Array(raw)
            guard bytes.count == 16 else { return .other }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return scopeIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 {
                return .loopback
            }
            // Link-local fe80::/10
            if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return .other }
            // AWS metadata fd00:ec2::/32
            if bytes[0] == 0xFD, bytes[1] == 0x00, bytes[2] == 0x0E, bytes[3] == 0xC2 {
                return .other
            }
            // Tailscale ULA fd7a:115c:a1e0::/48
            if Array(bytes.prefix(6)) == tailscaleULA { return .tailnet }
            // Unique local fc00::/7
            if (bytes[0] & 0xFE) == 0xFC { return .lan }
            return .other
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
