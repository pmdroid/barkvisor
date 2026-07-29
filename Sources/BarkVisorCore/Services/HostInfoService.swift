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

    public init(name: String, displayName: String, ipAddress: String, bridgeStatus: String?) {
        self.name = name
        self.displayName = displayName
        self.ipAddress = ipAddress
        self.bridgeStatus = bridgeStatus
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

    /// Check whether a network interface name exists on this host.
    public static func interfaceExists(_ name: String) -> Bool {
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
    /// - Parameter bridgeStatusByInterface: map of interface name → BridgeRecord.status
    public static func listInterfaceSnapshots(
        bridgeStatusByInterface: [String: String] = [:],
    ) -> [HostInterfaceSnapshot] {
        listInterfaces().map { iface in
            HostInterfaceSnapshot(
                name: iface.name,
                displayName: displayName(for: iface.name),
                ipAddress: iface.ipAddress,
                bridgeStatus: apiBridgeStatus(bridgeStatusByInterface[iface.name]),
            )
        }
    }
}
