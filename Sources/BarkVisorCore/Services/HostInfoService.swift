import Foundation

public struct HostInterfaceInfo {
    public let name: String
    public let ipAddress: String

    public init(name: String, ipAddress: String) {
        self.name = name
        self.ipAddress = ipAddress
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
                if getnameinfo(
                    ifaAddr, socklen_t(ifaAddr.pointee.sa_len),
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
}
