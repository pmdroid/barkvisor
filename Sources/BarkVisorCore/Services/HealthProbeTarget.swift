#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// Who may be contacted from the host for a guest probe.
///
/// NAT / isolated: hostfwd only. Bridged: guest-reported IPs that pass the
/// private-unicast filter, optionally restricted to on-link prefixes of the
/// VM's bridge.
public struct HealthProbePolicy: Sendable, Equatable {
    public var allowGuestReportedIPs: Bool
    public var guestIPv4Prefixes: [IPv4Prefix]

    public static let hostfwdOnly = HealthProbePolicy(
        allowGuestReportedIPs: false, guestIPv4Prefixes: [],
    )
    public static let allowPrivateGuestIPs = HealthProbePolicy(
        allowGuestReportedIPs: true, guestIPv4Prefixes: [],
    )

    public init(allowGuestReportedIPs: Bool, guestIPv4Prefixes: [IPv4Prefix] = []) {
        self.allowGuestReportedIPs = allowGuestReportedIPs
        self.guestIPv4Prefixes = guestIPv4Prefixes
    }
}

public struct IPv4Prefix: Sendable, Equatable {
    public var network: UInt32
    public var mask: UInt32

    public init(network: UInt32, mask: UInt32) {
        self.network = network
        self.mask = mask
    }

    public func contains(_ ip: String) -> Bool {
        guard let value = HealthProbeTarget.ipv4Value(ip) else { return false }
        return (value & mask) == (network & mask)
    }
}

/// Resolves a guest probe destination. Prefer hostfwd so NAT VMs are reachable.
public enum HealthProbeTarget: Equatable, Sendable {
    public struct Resolved: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var via: String
    }

    /// QEMU user-net guest address — not reachable from the host.
    public static let slirpGuestIPv4 = "10.0.2.15"

    public static func policy(for network: Network?) -> HealthProbePolicy {
        let mode = (try? NetworkCapability.effectiveMode(of: network)) ?? .nat
        guard mode == .bridged else { return .hostfwdOnly }
        let prefixes = network?.bridge.map { hostIPv4Prefixes(interface: $0) } ?? []
        return HealthProbePolicy(allowGuestReportedIPs: true, guestIPv4Prefixes: prefixes)
    }

    public static func resolve(
        port: Int,
        vm: VM,
        guestIPs: [String],
        policy: HealthProbePolicy = .hostfwdOnly,
    ) -> Resolved? {
        if let rule = vm.decodedPortForwards.first(where: {
            $0.protocol == "tcp" && $0.guestPort == port
        }) {
            return Resolved(host: "127.0.0.1", port: rule.hostPort, via: "hostfwd")
        }
        guard policy.allowGuestReportedIPs else { return nil }
        for ip in guestIPs where isAllowedGuestIP(ip, policy: policy) {
            return Resolved(host: ip, port: port, via: "guest")
        }
        return nil
    }

    public static func isAllowedGuestIP(_ ip: String, policy: HealthProbePolicy) -> Bool {
        guard isReachableGuestIP(ip) else { return false }
        if !policy.guestIPv4Prefixes.isEmpty, isReachableGuestIPv4(ip) {
            return policy.guestIPv4Prefixes.contains { $0.contains(ip) }
        }
        return true
    }

    public static func isReachableGuestIP(_ ip: String) -> Bool {
        if isReachableGuestIPv4(ip) { return true }
        return isReachableGuestIPv6(ip)
    }

    public static func isReachableGuestIPv4(_ ip: String) -> Bool {
        if ip == slirpGuestIPv4 { return false }
        guard let value = ipv4Value(ip) else { return false }
        let a = UInt8(truncatingIfNeeded: value >> 24)
        let b = UInt8(truncatingIfNeeded: value >> 16)
        if a == 0 || a == 127 || a >= 224 { return false }
        if a == 169, b == 254 { return false } // link-local / cloud metadata
        if a == 10 { return true }
        if a == 172, (16 ... 31).contains(b) { return true }
        if a == 192, b == 168 { return true }
        return false
    }

    public static func isReachableGuestIPv6(_ ip: String) -> Bool {
        let bare = ip.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ip
        let lower = bare.lowercased()
        if lower == "::1" || lower == "::" { return false }
        if lower.hasPrefix("fe80:") { return false }
        if lower.hasPrefix("::ffff:") {
            return isReachableGuestIPv4(String(lower.dropFirst(7)))
        }
        var addr = in6_addr()
        guard bare.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) else { return false }
        let first = lower.split(separator: ":", omittingEmptySubsequences: false).first
            .map(String.init) ?? ""
        return first.hasPrefix("fc") || first.hasPrefix("fd")
    }

    public static func ipv4Value(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    /// IPv4 prefixes currently configured on `interface` (empty if unknown).
    public static func hostIPv4Prefixes(interface: String) -> [IPv4Prefix] {
        guard !interface.isEmpty else { return [] }
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }

        var prefixes: [IPv4Prefix] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let addr = current {
            defer { current = addr.pointee.ifa_next }
            let name = String(cString: addr.pointee.ifa_name)
            guard name == interface else { continue }
            guard let ifaAddr = addr.pointee.ifa_addr,
                  ifaAddr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            guard let maskPtr = addr.pointee.ifa_netmask,
                  maskPtr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var sin = sockaddr_in()
            var mask = sockaddr_in()
            memcpy(&sin, ifaAddr, MemoryLayout<sockaddr_in>.size)
            memcpy(&mask, maskPtr, MemoryLayout<sockaddr_in>.size)
            let network = UInt32(bigEndian: sin.sin_addr.s_addr)
            let netmask = UInt32(bigEndian: mask.sin_addr.s_addr)
            prefixes.append(IPv4Prefix(network: network & netmask, mask: netmask))
        }
        return prefixes
    }
}
