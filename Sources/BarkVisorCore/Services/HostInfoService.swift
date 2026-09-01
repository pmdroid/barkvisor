import Foundation

public struct HostInterfaceInfo: Sendable {
    public let name: String
    public let ipAddress: String

    public init(name: String, ipAddress: String) {
        self.name = name
        self.ipAddress = ipAddress
    }
}

/// Interface row ready for setup/system API mapping (display + optional bridge status).
public struct HostInterfaceSnapshot: Sendable {
    public let name: String
    public let displayName: String
    public let ipAddress: String
    /// Bridge daemon status for this interface, or nil when not configured / unknown.
    public let bridgeStatus: String?
    /// Live IPv4 addresses on this interface (#434).
    public let addresses: [HostInterfaceAddressEntry]
    public let dhcpEnabled: Bool
    public let gateway: String?
    public let dns: [String]
    public let managedByBarkvisor: Bool

    public init(
        name: String,
        displayName: String,
        ipAddress: String,
        bridgeStatus: String?,
        addresses: [HostInterfaceAddressEntry] = [],
        dhcpEnabled: Bool = false,
        gateway: String? = nil,
        dns: [String] = [],
        managedByBarkvisor: Bool = false,
    ) {
        self.name = name
        self.displayName = displayName
        self.ipAddress = ipAddress
        self.bridgeStatus = bridgeStatus
        self.addresses = addresses
        self.dhcpEnabled = dhcpEnabled
        self.gateway = gateway
        self.dns = dns
        self.managedByBarkvisor = managedByBarkvisor
    }
}

public enum HostInfoService {
    /// List all IPv4 network interfaces on this host.
    public static func listInterfaces() -> [HostInterfaceInfo] {
        var interfaces: [HostInterfaceInfo] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return interfaces
        }
        defer { freeifaddrs(firstAddr) }

        var seen = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let addr = current {
            let name = String(cString: addr.pointee.ifa_name)

            if let ifaAddr = addr.pointee.ifa_addr, ifaAddr.pointee.sa_family == UInt8(AF_INET),
               !seen.contains(name) {
                seen.insert(name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    let addrLen = socklen_t(ifaAddr.pointee.sa_len)
                #else
                    // Linux sockaddr has no sa_len; use sockaddr_in size for AF_INET.
                    let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                if getnameinfo(
                    ifaAddr, addrLen,
                    &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST,
                ) == 0 {
                    let ip = hostname.withUnsafeBufferPointer {
                        String(bytes: $0.prefix(while: { $0 != 0 }).map(UInt8.init), encoding: .utf8) ?? ""
                    }
                    interfaces.append(HostInterfaceInfo(name: name, ipAddress: ip))
                }
            }
            current = addr.pointee.ifa_next
        }

        return interfaces
    }

    /// All currently assigned IPv4 and IPv6 addresses (one row per address).
    /// `listInterfaces()` stays IPv4-only for setup/system UI.
    public static func listInterfaceAddresses() -> [HostInterfaceInfo] {
        var interfaces: [HostInterfaceInfo] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return interfaces
        }
        defer { freeifaddrs(firstAddr) }

        var seen = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = current {
            let name = String(cString: addr.pointee.ifa_name)
            if let ifaAddr = addr.pointee.ifa_addr {
                let family = Int32(ifaAddr.pointee.sa_family)
                if family == AF_INET || family == AF_INET6,
                   let ip = numericHost(ifaAddr) {
                    let key = "\(name)\0\(ip)"
                    if seen.insert(key).inserted {
                        interfaces.append(HostInterfaceInfo(name: name, ipAddress: ip))
                    }
                }
            }
            current = addr.pointee.ifa_next
        }
        return interfaces
    }

    private static func numericHost(_ ifaAddr: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(ifaAddr.pointee.sa_family)
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            let addrLen = socklen_t(ifaAddr.pointee.sa_len)
        #else
            let addrLen: socklen_t = family == AF_INET6
                ? socklen_t(MemoryLayout<sockaddr_in6>.size)
                : socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            ifaAddr, addrLen,
            &hostname, socklen_t(hostname.count),
            nil, 0, NI_NUMERICHOST,
        ) == 0 else {
            return nil
        }
        var ip = hostname.withUnsafeBufferPointer {
            String(bytes: $0.prefix(while: { $0 != 0 }).map(UInt8.init), encoding: .utf8) ?? ""
        }
        if let zone = ip.firstIndex(of: "%") {
            ip = String(ip[..<zone])
        }
        return ip.isEmpty ? nil : ip
    }

    /// Whether a network interface name exists on this host.
    ///
    /// **Down and address-less interfaces count as present** — a Linux bridge
    /// used with QEMU `-netdev bridge` may have no IPv4 address and still be valid.
    ///
    /// Single definition used by setup/system routes, privilege paths, and VM start:
    /// - **Linux:** `/sys/class/net/<name>` (sysfs), same as `LinuxHostNetwork`.
    /// - **macOS / others:** `getifaddrs` name match (any address family).
    ///
    /// `listInterfaces()` only returns interfaces that currently have an IPv4 address;
    /// an interface can therefore exist without appearing in that list.
    public static func interfaceExists(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            return false
        }
        #if os(Linux)
            return LinuxHostNetwork.interfaceExists(name)
        #else
            return interfaceExistsViaGetifaddrs(name)
        #endif
    }

    /// BSD/macOS existence probe via getifaddrs (includes interfaces without IPv4).
    private static func interfaceExistsViaGetifaddrs(_ name: String) -> Bool {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return false
        }
        defer { freeifaddrs(firstAddr) }
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = current {
            if String(cString: addr.pointee.ifa_name) == name {
                return true
            }
            current = addr.pointee.ifa_next
        }
        return false
    }

    /// Human-readable label for setup / system UI (macOS + Linux host names).
    public static func displayName(for name: String) -> String {
        #if os(Linux)
            if name == "lo" {
                return "lo (Loopback)"
            }
            if name.hasPrefix("br") || name.hasPrefix("virbr") || name.hasPrefix("ovs-") {
                return "\(name) (Bridge)"
            }
            if name.hasPrefix("docker") || name.hasPrefix("cni") || name.hasPrefix("flannel")
                || name.hasPrefix("veth") {
                return "\(name) (Container)"
            }
            if name.hasPrefix("wl") || name.hasPrefix("wlan") || name.hasPrefix("wlp") {
                return "\(name) (Wi-Fi)"
            }
            if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("enp")
                || name.hasPrefix("ens") || name.hasPrefix("eno") {
                return "\(name) (Ethernet)"
            }
            if name.hasPrefix("bond") {
                return "\(name) (Bond)"
            }
            if name.hasPrefix("tun") || name.hasPrefix("tap") {
                return "\(name) (TUN/TAP)"
            }
            return name
        #else
            if name.hasPrefix("en") {
                return "\(name) (Ethernet/Wi-Fi)"
            }
            if name.hasPrefix("bridge") {
                return "\(name) (Bridge)"
            }
            if name == "lo0" {
                return "lo0 (Loopback)"
            }
            return name
        #endif
    }

    /// Map DB bridge status for API clients (`not_configured` → nil).
    public static func apiBridgeStatus(_ status: String?) -> String? {
        guard let status, status != "not_configured" else { return nil }
        return status
    }

    /// List host interfaces with display names and optional per-interface bridge status.
    ///
    /// On Linux, also includes **bridge devices without an IPv4 address** (from sysfs).
    /// `listInterfaces()` is IPv4-only, so a bare `br0` would otherwise be missing from the UI.
    /// - Parameter bridgeStatusByInterface: map of interface name → status
    ///   (macOS: BridgeRecord; Linux: HostBridgeFacts)
    public static func listInterfaceSnapshots(
        bridgeStatusByInterface: [String: String] = [:],
        addressingByInterface: [String: HostInterfaceAddressing]? = nil,
    ) -> [HostInterfaceSnapshot] {
        var byName: [String: HostInterfaceSnapshot] = [:]
        let addressing = addressingByInterface ?? HostInterfaceAddressDiscovery.discoverByInterface()

        for iface in listInterfaces() {
            let config = addressing[iface.name] ?? HostInterfaceAddressing()
            byName[iface.name] = HostInterfaceSnapshot(
                name: iface.name,
                displayName: displayName(for: iface.name),
                ipAddress: primaryIPv4(from: config) ?? iface.ipAddress,
                bridgeStatus: apiBridgeStatus(bridgeStatusByInterface[iface.name]),
                addresses: config.addresses,
                dhcpEnabled: config.dhcpEnabled,
                gateway: config.gateway,
                dns: config.dns,
                managedByBarkvisor: config.managedByBarkvisor,
            )
        }

        #if os(Linux)
            // Merge bridge-class devices that have no AF_INET address (down / L2-only).
            for name in HostBridgeFactsService.probe().bridges.map(\.name) {
                if byName[name] != nil { continue }
                let config = addressing[name] ?? HostInterfaceAddressing()
                byName[name] = HostInterfaceSnapshot(
                    name: name,
                    displayName: displayName(for: name),
                    ipAddress: primaryIPv4(from: config) ?? "",
                    bridgeStatus: apiBridgeStatus(bridgeStatusByInterface[name]),
                    addresses: config.addresses,
                    dhcpEnabled: config.dhcpEnabled,
                    gateway: config.gateway,
                    dns: config.dns,
                    managedByBarkvisor: config.managedByBarkvisor,
                )
            }
        #endif

        return byName.values.sorted { $0.name < $1.name }
    }

    /// First primary IPv4 CIDR, or first address, for legacy `ipAddress` field.
    static func primaryIPv4(from config: HostInterfaceAddressing) -> String? {
        let primary = config.addresses.first(where: \.primary) ?? config.addresses.first
        guard let cidr = primary?.cidr else { return nil }
        return HostInterfaceAddressDiscovery.ipFromCIDR(cidr)
    }
}
