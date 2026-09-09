import Foundation
#if canImport(WinSDK)
    import WinSDK
#endif

public struct HostInterfaceInfo: Sendable {
    public let name: String
    public let ipAddress: String
    public let prefixLength: Int?

    public init(name: String, ipAddress: String, prefixLength: Int? = nil) {
        self.name = name
        self.ipAddress = ipAddress
        self.prefixLength = prefixLength
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
    /// Linux sysfs `operstate` (`up`, `down`, …); nil on macOS or when unreadable.
    public let operState: String?
    /// Linux sysfs `carrier` (cable/link detected). Nil when absent (common on bridges).
    public let carrier: Bool?
    /// Linux bridge master when this port is enslaved (`/sys/class/net/<name>/master`).
    public let bridgeMaster: String?

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
        operState: String? = nil,
        carrier: Bool? = nil,
        bridgeMaster: String? = nil,
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
        self.operState = operState
        self.carrier = carrier
        self.bridgeMaster = bridgeMaster
    }
}

public struct WindowsAdapterRow: Sendable, Equatable {
    public var friendlyName: String
    public var ifType: UInt32
    public var address: String?
    public var prefixLength: Int?
    public var operUp: Bool

    public init(
        friendlyName: String,
        ifType: UInt32,
        address: String? = nil,
        prefixLength: Int? = nil,
        operUp: Bool = true,
    ) {
        self.friendlyName = friendlyName
        self.ifType = ifType
        self.address = address
        self.prefixLength = prefixLength
        self.operUp = operUp
    }
}

public enum HostInfoService {
    public static let windowsLoopbackIfType: UInt32 = 24

    public static func windowsInterfaceName(friendlyName: String, ifType: UInt32) -> String {
        if ifType == windowsLoopbackIfType {
            return "Loopback"
        }
        return friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func strippedNumericHost(_ ip: String) -> String {
        if let zone = ip.firstIndex(of: "%") {
            return String(ip[..<zone])
        }
        return ip
    }

    public static func listInterfaces(fromWindowsRows rows: [WindowsAdapterRow]) -> [HostInterfaceInfo] {
        var seen = Set<String>()
        var interfaces: [HostInterfaceInfo] = []
        for row in rows {
            let name = windowsInterfaceName(friendlyName: row.friendlyName, ifType: row.ifType)
            guard !name.isEmpty, let raw = row.address, !raw.isEmpty else { continue }
            let ip = strippedNumericHost(raw)
            guard !ip.contains(":") else { continue }
            guard seen.insert(name).inserted else { continue }
            interfaces.append(HostInterfaceInfo(name: name, ipAddress: ip, prefixLength: row.prefixLength))
        }
        return interfaces
    }

    public static func listInterfaceAddresses(fromWindowsRows rows: [WindowsAdapterRow]) -> [HostInterfaceInfo] {
        var seen = Set<String>()
        var interfaces: [HostInterfaceInfo] = []
        for row in rows {
            let name = windowsInterfaceName(friendlyName: row.friendlyName, ifType: row.ifType)
            guard !name.isEmpty, let raw = row.address, !raw.isEmpty else { continue }
            let ip = strippedNumericHost(raw)
            guard !ip.isEmpty else { continue }
            let key = "\(name)\0\(ip)"
            guard seen.insert(key).inserted else { continue }
            let prefix = ip.contains(":") ? nil : row.prefixLength
            interfaces.append(HostInterfaceInfo(name: name, ipAddress: ip, prefixLength: prefix))
        }
        return interfaces
    }

    public static func interfaceExists(_ name: String, windowsRows: [WindowsAdapterRow]) -> Bool {
        guard !name.isEmpty else { return false }
        return windowsRows.contains {
            windowsInterfaceName(friendlyName: $0.friendlyName, ifType: $0.ifType) == name
        }
    }

    public static func linkFlags(fromWindowsRows rows: [WindowsAdapterRow]) -> [String: (operState: String, carrier: Bool?)] {
        var out: [String: (operState: String, carrier: Bool?)] = [:]
        for row in rows {
            let name = windowsInterfaceName(friendlyName: row.friendlyName, ifType: row.ifType)
            guard !name.isEmpty, out[name] == nil else { continue }
            out[name] = (row.operUp ? "up" : "down", row.operUp)
        }
        return out
    }

    /// List all IPv4 network interfaces on this host.
    public static func listInterfaces() -> [HostInterfaceInfo] {
        #if os(Windows)
            return listInterfaces(fromWindowsRows: listWindowsAdapterRows())
        #else
            return listInterfacesPOSIX()
        #endif
    }

    #if !os(Windows)
        private static func listInterfacesPOSIX() -> [HostInterfaceInfo] {
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
    #endif

    /// All currently assigned IPv4 and IPv6 addresses (one row per address).
    /// `listInterfaces()` stays IPv4-only for setup/system UI.
    public static func listInterfaceAddresses() -> [HostInterfaceInfo] {
        #if os(Windows)
            return listInterfaceAddresses(fromWindowsRows: listWindowsAdapterRows())
        #else
            return listInterfaceAddressesPOSIX()
        #endif
    }

    #if !os(Windows)
        private static func listInterfaceAddressesPOSIX() -> [HostInterfaceInfo] {
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
                            interfaces.append(HostInterfaceInfo(
                                name: name,
                                ipAddress: ip,
                                prefixLength: family == AF_INET ? ipv4PrefixLength(addr.pointee) : nil,
                            ))
                        }
                    }
                }
                current = addr.pointee.ifa_next
            }
            return interfaces
        }

        private static func ipv4PrefixLength(_ ifa: ifaddrs) -> Int? {
            guard let maskPtr = ifa.ifa_netmask else { return nil }
            guard Int32(maskPtr.pointee.sa_family) == AF_INET else { return nil }
            return maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                Int(UInt32(bigEndian: ptr.pointee.sin_addr.s_addr).nonzeroBitCount)
            }
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
    #endif

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
        #elseif os(Windows)
            return interfaceExists(name, windowsRows: listWindowsAdapterRows())
        #else
            return interfaceExistsViaGetifaddrs(name)
        #endif
    }

    #if !os(Windows)
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
    #endif

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
            if name.hasPrefix("br") || name.hasPrefix("bridge") {
                return "\(name) (Bridge)"
            }
            if name.hasPrefix("en") {
                return "\(name) (Ethernet/Wi-Fi)"
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
        syntheticBridges: [HostBridgeSnapshot]? = nil,
    ) -> [HostInterfaceSnapshot] {
        var byName: [String: HostInterfaceSnapshot] = [:]
        let addressing = addressingByInterface ?? HostInterfaceAddressDiscovery.discoverByInterface()
        let linkFlags = linkFlagsByInterface()

        for iface in listInterfaces() {
            let config = addressing[iface.name] ?? HostInterfaceAddressing()
            byName[iface.name] = snapshot(
                name: iface.name,
                ipAddress: primaryIPv4(from: config) ?? iface.ipAddress,
                bridgeStatusByInterface: bridgeStatusByInterface,
                config: config,
                link: linkFlags[iface.name],
            )
        }

        #if os(Linux)
            // Merge sysfs interfaces without AF_INET (down NICs, bridge members, L2-only bridges).
            for name in LinuxHostNetwork.listHostInterfaceNames() {
                if byName[name] != nil { continue }
                let config = addressing[name] ?? HostInterfaceAddressing()
                byName[name] = snapshot(
                    name: name,
                    ipAddress: primaryIPv4(from: config) ?? "",
                    bridgeStatusByInterface: bridgeStatusByInterface,
                    config: config,
                    link: linkFlags[name],
                )
            }
        #endif

        let extras: [HostBridgeSnapshot]
        if let syntheticBridges {
            extras = syntheticBridges
        } else {
            #if os(macOS)
                extras = HostBridgeFactsService.probe().bridges
            #else
                extras = []
            #endif
        }
        for snap in extras {
            if byName[snap.name] != nil { continue }
            let overlayUplink = !interfaceExists(snap.name)
            let config: HostInterfaceAddressing = if overlayUplink, let uplink = snap.enslaved.first, let fromUplink = addressing[uplink] {
                fromUplink
            } else {
                addressing[snap.name] ?? HostInterfaceAddressing()
            }
            byName[snap.name] = snapshot(
                name: snap.name,
                ipAddress: primaryIPv4(from: config) ?? "",
                bridgeStatusByInterface: bridgeStatusByInterface,
                config: config,
                link: linkFlags[snap.name],
            )
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    private static func snapshot(
        name: String,
        ipAddress: String,
        bridgeStatusByInterface: [String: String],
        config: HostInterfaceAddressing,
        link: (operState: String, carrier: Bool?)? = nil,
    ) -> HostInterfaceSnapshot {
        #if os(Linux)
            return HostInterfaceSnapshot(
                name: name,
                displayName: displayName(for: name),
                ipAddress: ipAddress,
                bridgeStatus: apiBridgeStatus(bridgeStatusByInterface[name]),
                addresses: config.addresses,
                dhcpEnabled: config.dhcpEnabled,
                gateway: config.gateway,
                dns: config.dns,
                managedByBarkvisor: config.managedByBarkvisor,
                operState: LinuxHostNetwork.interfaceOperState(name) ?? link?.operState,
                carrier: LinuxHostNetwork.interfaceCarrier(name) ?? link?.carrier,
                bridgeMaster: LinuxHostNetwork.bridgeMaster(for: name),
            )
        #else
            return HostInterfaceSnapshot(
                name: name,
                displayName: displayName(for: name),
                ipAddress: ipAddress,
                bridgeStatus: apiBridgeStatus(bridgeStatusByInterface[name]),
                addresses: config.addresses,
                dhcpEnabled: config.dhcpEnabled,
                gateway: config.gateway,
                dns: config.dns,
                managedByBarkvisor: config.managedByBarkvisor,
                operState: link?.operState,
                carrier: link?.carrier,
            )
        #endif
    }

    private static func linkFlagsByInterface() -> [String: (operState: String, carrier: Bool?)] {
        #if os(Windows)
            return linkFlags(fromWindowsRows: listWindowsAdapterRows())
        #else
            var out: [String: (operState: String, carrier: Bool?)] = [:]
            var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return out }
            defer { freeifaddrs(first) }
            var current: UnsafeMutablePointer<ifaddrs>? = first
            while let addr = current {
                let name = String(cString: addr.pointee.ifa_name)
                if out[name] == nil {
                    let flags = addr.pointee.ifa_flags
                    let up = (flags & UInt32(IFF_UP)) != 0
                    let running = (flags & UInt32(IFF_RUNNING)) != 0
                    out[name] = (up ? "up" : "down", running)
                }
                current = addr.pointee.ifa_next
            }
            return out
        #endif
    }

    /// First primary IPv4 CIDR, or first address, for legacy `ipAddress` field.
    static func primaryIPv4(from config: HostInterfaceAddressing) -> String? {
        let primary = config.addresses.first(where: \.primary) ?? config.addresses.first
        guard let cidr = primary?.cidr else { return nil }
        return HostInterfaceAddressDiscovery.ipFromCIDR(cidr)
    }

    #if os(Windows)
        private static func listWindowsAdapterRows() -> [WindowsAdapterRow] {
            do {
                try PlatformSocket.ensureStarted()
            } catch {
                return []
            }
            let flags = ULONG(truncatingIfNeeded: GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER)
            var size: ULONG = 15_360
            var buffer = [UInt8](repeating: 0, count: Int(size))
            var result = ULONG(truncatingIfNeeded: ERROR_BUFFER_OVERFLOW)
            for _ in 0 ..< 3 {
                result = buffer.withUnsafeMutableBytes { raw -> ULONG in
                    guard let base = raw.baseAddress else { return ULONG(truncatingIfNeeded: ERROR_INVALID_PARAMETER) }
                    let ptr = base.bindMemory(to: IP_ADAPTER_ADDRESSES.self, capacity: 1)
                    return GetAdaptersAddresses(ULONG(truncatingIfNeeded: AF_UNSPEC), flags, nil, ptr, &size)
                }
                if result == ULONG(truncatingIfNeeded: NO_ERROR) { break }
                if result != ULONG(truncatingIfNeeded: ERROR_BUFFER_OVERFLOW) { return [] }
                buffer = [UInt8](repeating: 0, count: Int(size))
            }
            guard result == ULONG(truncatingIfNeeded: NO_ERROR) else { return [] }
            var rows: [WindowsAdapterRow] = []
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                var current: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>? =
                    base.bindMemory(to: IP_ADAPTER_ADDRESSES.self, capacity: 1)
                while let adapter = current {
                    let friendly = if let namePtr = adapter.pointee.FriendlyName {
                        String(decodingCString: namePtr, as: UTF16.self)
                    } else {
                        ""
                    }
                    let ifType = UInt32(adapter.pointee.IfType)
                    let operUp = adapter.pointee.OperStatus == IfOperStatusUp
                    var emitted = false
                    var unicast = adapter.pointee.FirstUnicastAddress
                    while let addr = unicast {
                        if let sa = addr.pointee.Address.lpSockaddr,
                           let ip = numericAddress(sa), !ip.isEmpty {
                            rows.append(WindowsAdapterRow(
                                friendlyName: friendly,
                                ifType: ifType,
                                address: ip,
                                prefixLength: Int(addr.pointee.OnLinkPrefixLength),
                                operUp: operUp,
                            ))
                            emitted = true
                        }
                        unicast = addr.pointee.Next
                    }
                    if !emitted {
                        rows.append(WindowsAdapterRow(
                            friendlyName: friendly,
                            ifType: ifType,
                            address: nil,
                            prefixLength: nil,
                            operUp: operUp,
                        ))
                    }
                    current = adapter.pointee.Next
                }
            }
            return rows
        }

        private static func numericAddress(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
            let family = Int32(sa.pointee.sa_family)
            if family == AF_INET {
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var inAddr = sin.pointee.sin_addr
                    guard inet_ntop(AF_INET, &inAddr, &buf, Int(INET_ADDRSTRLEN)) != nil else {
                        return nil
                    }
                    return String(cString: buf)
                }
            }
            if family == AF_INET6 {
                return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var in6 = sin6.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &in6, &buf, Int(INET6_ADDRSTRLEN)) != nil else {
                        return nil
                    }
                    return strippedNumericHost(String(cString: buf))
                }
            }
            return nil
        }
    #endif
}
