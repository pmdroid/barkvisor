import Foundation

public enum HostInterfaceAddressSource: String, Codable, Sendable, Equatable {
    case dhcp
    case `static`
    case alias
}

public struct HostInterfaceAddressEntry: Codable, Sendable, Equatable {
    public var cidr: String
    public var source: HostInterfaceAddressSource
    public var primary: Bool

    public init(cidr: String, source: HostInterfaceAddressSource, primary: Bool = false) {
        self.cidr = cidr
        self.source = source
        self.primary = primary
    }
}

/// Live OS addressing for one host interface (read-only; never mutates).
public struct HostInterfaceAddressing: Sendable, Equatable {
    public var addresses: [HostInterfaceAddressEntry]
    public var dhcpEnabled: Bool
    public var gateway: String?
    public var dns: [String]
    public var managedByBarkvisor: Bool

    public init(
        addresses: [HostInterfaceAddressEntry] = [],
        dhcpEnabled: Bool = false,
        gateway: String? = nil,
        dns: [String] = [],
        managedByBarkvisor: Bool = false,
    ) {
        self.addresses = addresses
        self.dhcpEnabled = dhcpEnabled
        self.gateway = gateway
        self.dns = dns
        self.managedByBarkvisor = managedByBarkvisor
    }
}

/// Reads current interface addressing from the OS for Networks / Bridge setup (#434).
public enum HostInterfaceAddressDiscovery {
    /// Map interface name → live addressing. Detection only — never mutates the host.
    public static func discoverByInterface(
        liveAddresses: [HostInterfaceInfo] = HostInfoService.listInterfaceAddresses(),
        interfaceNames: [String]? = nil,
    ) -> [String: HostInterfaceAddressing] {
        let names = interfaceNames ?? unionInterfaceNames(liveAddresses: liveAddresses)
        var result: [String: HostInterfaceAddressing] = [:]
        for name in names {
            let liveIPv4 = liveIPv4Addresses(for: name, from: liveAddresses)
            result[name] = discover(
                interface: name,
                liveIPv4: liveIPv4,
            )
        }
        return result
    }

    /// Merge configured addressing with live `getifaddrs` rows (aliases not in config → `.alias`).
    public static func mergeLiveAddresses(
        config: HostInterfaceAddressing,
        liveIPv4: [String],
    ) -> HostInterfaceAddressing {
        var merged = config
        let configuredCIDRs = Set(merged.addresses.map(\.cidr))
        let configuredIPs = Set(merged.addresses.map { ipFromCIDR($0.cidr) })
        let configuredDHCPIP = merged.addresses.first(where: { $0.source == .dhcp })
            .map { ipFromCIDR($0.cidr) }
        for (index, ip) in liveIPv4.enumerated() {
            if merged.dhcpEnabled, isLiveDHCPCandidate(ip: ip, index: index, configuredDHCPIP: configuredDHCPIP) {
                continue
            }
            let cidr = inferCIDR(ip: ip, existing: merged.addresses)
            if configuredCIDRs.contains(cidr) || configuredIPs.contains(ip) {
                continue
            }
            merged.addresses.append(
                HostInterfaceAddressEntry(cidr: cidr, source: .alias, primary: false),
            )
        }
        if merged.addresses.isEmpty, !liveIPv4.isEmpty {
            for (index, ip) in liveIPv4.enumerated() {
                merged.addresses.append(
                    HostInterfaceAddressEntry(
                        cidr: inferCIDR(ip: ip, existing: merged.addresses),
                        source: merged.dhcpEnabled && index == 0 ? .dhcp : .alias,
                        primary: index == 0,
                    ),
                )
            }
        } else if merged.dhcpEnabled {
            for (index, ip) in liveIPv4.enumerated() {
                guard isLiveDHCPCandidate(ip: ip, index: index, configuredDHCPIP: configuredDHCPIP) else {
                    continue
                }
                let cidr = inferCIDR(ip: ip, existing: merged.addresses)
                if let rowIndex = merged.addresses.firstIndex(where: {
                    HostInterfaceAddressDiscovery.ipFromCIDR($0.cidr) == ip
                }) {
                    var row = merged.addresses.remove(at: rowIndex)
                    row.source = .dhcp
                    row.primary = true
                    merged.addresses.insert(row, at: 0)
                } else {
                    merged.addresses.insert(
                        HostInterfaceAddressEntry(cidr: cidr, source: .dhcp, primary: true),
                        at: 0,
                    )
                }
            }
        }
        if merged.addresses.contains(where: \.primary) == false, !merged.addresses.isEmpty {
            merged.addresses[0].primary = true
        }
        if merged.dhcpEnabled {
            for index in merged.addresses.indices where !merged.addresses[index].primary
                && merged.addresses[index].source == .static {
                merged.addresses[index].source = .alias
            }
        }
        return merged
    }

    /// When `networksetup` supplied a DHCP lease, prefer that IP over `getifaddrs` ordering.
    private static func isLiveDHCPCandidate(
        ip: String,
        index: Int,
        configuredDHCPIP: String?,
    ) -> Bool {
        if let configuredDHCPIP {
            return ip == configuredDHCPIP
        }
        return index == 0
    }

    // MARK: - Platform discovery

    private static func discover(interface: String, liveIPv4: [String]) -> HostInterfaceAddressing {
        #if os(macOS)
            return discoverMac(interface: interface, liveIPv4: liveIPv4)
        #elseif os(Linux)
            return discoverLinux(interface: interface, liveIPv4: liveIPv4)
        #else
            return fallbackFromLive(liveIPv4: liveIPv4)
        #endif
    }

    private static func unionInterfaceNames(liveAddresses: [HostInterfaceInfo]) -> [String] {
        var names = Set(liveAddresses.map(\.name))
        #if os(Linux)
            for name in LinuxHostNetwork.listHostInterfaceNames() {
                names.insert(name)
            }
        #endif
        return names.sorted()
    }

    private static func liveIPv4Addresses(
        for interface: String,
        from rows: [HostInterfaceInfo],
    ) -> [String] {
        rows.filter { $0.name == interface && !$0.ipAddress.contains(":") }.map(\.ipAddress)
    }

    private static func fallbackFromLive(liveIPv4: [String]) -> HostInterfaceAddressing {
        var addressing = HostInterfaceAddressing()
        for (index, ip) in liveIPv4.enumerated() {
            addressing.addresses.append(
                HostInterfaceAddressEntry(
                    cidr: "\(ip)/32",
                    source: .alias,
                    primary: index == 0,
                ),
            )
        }
        return addressing
    }

    // MARK: - Shared helpers

    public static func ipFromCIDR(_ cidr: String) -> String {
        cidr.split(separator: "/").first.map(String.init) ?? cidr
    }

    public static func cidr(ip: String, prefixLength: Int) -> String {
        "\(ip)/\(prefixLength)"
    }

    public static func prefixLength(fromMask mask: String) -> Int? {
        let parts = mask.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            value = (value << 8) | UInt32(part)
        }
        return value.nonzeroBitCount
    }

    static func inferCIDR(ip: String, existing: [HostInterfaceAddressEntry]) -> String {
        if let match = existing.first(where: { ipFromCIDR($0.cidr) == ip }) {
            return match.cidr
        }
        return "\(ip)/32"
    }
}

#if os(macOS)

    extension HostInterfaceAddressDiscovery {
        static func discoverMac(
            interface: String,
            liveIPv4: [String],
            ports: [MacHostNetworkApply.HardwarePort]? = nil,
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 15)
            },
        ) -> HostInterfaceAddressing {
            guard !MacHostNetworkApply.isLoopbackDevice(interface) else {
                return fallbackFromLive(liveIPv4: liveIPv4)
            }
            let managed = MacHostNetworkApply.readMarker(device: interface) != nil
            guard let service = try? MacHostNetworkApply.serviceName(
                forDevice: interface,
                ports: ports,
            ) else {
                return mergeLiveAddresses(
                    config: HostInterfaceAddressing(managedByBarkvisor: managed),
                    liveIPv4: liveIPv4,
                )
            }
            let infoText: String
            let dnsServers: [String]
            let additionalText: String
            if let info = try? run(MacHostNetworkApply.networksetupPath, ["-getinfo", service]),
               info.succeeded {
                infoText = info.stdoutString
            } else {
                infoText = ""
            }
            if let dns = try? run(MacHostNetworkApply.networksetupPath, ["-getdnsservers", service]),
               dns.succeeded {
                dnsServers = MacHostNetworkApply.parseDNSServers(dns.stdoutString)
            } else {
                dnsServers = []
            }
            if let extra = try? run(
                MacHostNetworkApply.networksetupPath,
                ["-listadditionalnetworkserviceaddress", service],
            ), extra.succeeded {
                additionalText = extra.stdoutString
            } else {
                additionalText = ""
            }

            let parsed = MacHostInterfaceAddressRead.parseGetInfo(infoText)
            let additional = MacHostInterfaceAddressRead.parseAdditionalAddresses(additionalText)
            let config = MacHostInterfaceAddressRead.buildAddressing(
                parsed: parsed,
                additionalCIDRs: additional,
                dns: dnsServers,
                managedByBarkvisor: managed,
            )
            return mergeLiveAddresses(config: config, liveIPv4: liveIPv4)
        }
    }

    /// Pure parsers for macOS `networksetup` output (testable with fixtures).
    public enum MacHostInterfaceAddressRead {
        public struct ParsedInfo: Sendable, Equatable {
            public var dhcpEnabled: Bool
            public var staticCIDR: String?
            /// Current DHCP lease from `networksetup -getinfo` (when in DHCP mode).
            public var dhcpCIDR: String?
            public var gateway: String?

            public init(
                dhcpEnabled: Bool = false,
                staticCIDR: String? = nil,
                dhcpCIDR: String? = nil,
                gateway: String? = nil,
            ) {
                self.dhcpEnabled = dhcpEnabled
                self.staticCIDR = staticCIDR
                self.dhcpCIDR = dhcpCIDR
                self.gateway = gateway
            }
        }

        public static func parseGetInfo(_ text: String) -> ParsedInfo {
            let lower = text.lowercased()
            var info = ParsedInfo()
            if lower.contains("dhcp configuration") {
                info.dhcpEnabled = true
                if let ip = MacHostNetworkApply.parseInfoValue(text, key: "IP address"),
                   let mask = MacHostNetworkApply.parseInfoValue(text, key: "Subnet mask"),
                   let prefix = HostInterfaceAddressDiscovery.prefixLength(fromMask: mask) {
                    info.dhcpCIDR = HostInterfaceAddressDiscovery.cidr(ip: ip, prefixLength: prefix)
                }
            } else if lower.contains("manual configuration") {
                info.dhcpEnabled = false
                if let ip = MacHostNetworkApply.parseInfoValue(text, key: "IP address"),
                   let mask = MacHostNetworkApply.parseInfoValue(text, key: "Subnet mask"),
                   let prefix = HostInterfaceAddressDiscovery.prefixLength(fromMask: mask) {
                    info.staticCIDR = HostInterfaceAddressDiscovery.cidr(ip: ip, prefixLength: prefix)
                }
            }
            info.gateway = MacHostNetworkApply.parseInfoValue(text, key: "Router")
            return info
        }

        public static func parseAdditionalAddresses(_ text: String) -> [String] {
            var cidrs: [String] = []
            var pendingIP: String?
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                if line.hasPrefix("Additional IPv4 Address:") || line.hasPrefix("Additional IP Address:") {
                    let ip = line.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    pendingIP = ip.isEmpty ? nil : ip
                } else if line.hasPrefix("Subnet mask:"), let ip = pendingIP,
                          let mask = line.split(separator: ":", maxSplits: 1).last?
                          .trimmingCharacters(in: .whitespaces),
                          let prefix = HostInterfaceAddressDiscovery.prefixLength(fromMask: mask) {
                    cidrs.append(HostInterfaceAddressDiscovery.cidr(ip: ip, prefixLength: prefix))
                    pendingIP = nil
                }
            }
            return cidrs
        }

        public static func buildAddressing(
            parsed: ParsedInfo,
            additionalCIDRs: [String],
            dns: [String],
            managedByBarkvisor: Bool,
        ) -> HostInterfaceAddressing {
            var addresses: [HostInterfaceAddressEntry] = []
            if parsed.dhcpEnabled, let cidr = parsed.dhcpCIDR {
                addresses.append(
                    HostInterfaceAddressEntry(cidr: cidr, source: .dhcp, primary: true),
                )
            } else if let cidr = parsed.staticCIDR {
                addresses.append(
                    HostInterfaceAddressEntry(cidr: cidr, source: .static, primary: true),
                )
            }
            for cidr in additionalCIDRs {
                addresses.append(
                    HostInterfaceAddressEntry(cidr: cidr, source: .alias, primary: false),
                )
            }
            return HostInterfaceAddressing(
                addresses: addresses,
                dhcpEnabled: parsed.dhcpEnabled,
                gateway: parsed.gateway,
                dns: dns,
                managedByBarkvisor: managedByBarkvisor,
            )
        }
    }

#endif

/// Pure parsers for Linux netplan / NetworkManager output (testable with fixtures).
public enum LinuxHostInterfaceAddressRead {
    public static func isBarkvisorManaged(_ yaml: String) -> Bool {
        yaml.contains("# managed-by: barkvisor") || yaml.contains("managed-by: barkvisor")
    }

    public static func parseNetplan(_ yaml: String, interface: String) -> HostInterfaceAddressing? {
        guard isBarkvisorManaged(yaml) else { return nil }
        var addressing = HostInterfaceAddressing(managedByBarkvisor: true)
        let lines = yaml.split(whereSeparator: \.isNewline).map(String.init)
        guard let block = netplanBlock(for: interface, in: lines) else {
            return nil
        }
        addressing.dhcpEnabled = block.contains(where: { $0.trimmedHostNet.hasPrefix("dhcp4: true") })
        var inNameservers = false
        for line in block {
            let trimmed = line.trimmedHostNet
            if trimmed.hasPrefix("nameservers:") {
                inNameservers = true
                continue
            }
            if inNameservers {
                if trimmed.hasPrefix("addresses:") {
                    addressing.dns = parseYAMLAddressList(trimmed).map {
                        HostInterfaceAddressDiscovery.ipFromCIDR($0)
                    }
                }
                continue
            }
            if trimmed.hasPrefix("addresses:") {
                for cidr in parseYAMLAddressList(trimmed) {
                    let source: HostInterfaceAddressSource =
                        addressing.dhcpEnabled || !addressing.addresses.isEmpty ? .alias : .static
                    addressing.addresses.append(
                        HostInterfaceAddressEntry(cidr: cidr, source: source, primary: false),
                    )
                }
            }
        }
        for (index, line) in block.enumerated() {
            let trimmed = line.trimmedHostNet
            if trimmed.hasPrefix("via:") {
                addressing.gateway = trimmed.dropFirst("via:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed == "- to: default", index + 1 < block.count {
                let next = block[index + 1].trimmedHostNet
                if next.hasPrefix("via:") {
                    addressing.gateway = next.dropFirst("via:".count)
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if !addressing.addresses.isEmpty, addressing.addresses.contains(where: \.primary) == false {
            addressing.addresses[0].primary = true
        }
        return addressing
    }

    public static func parseNmcliDeviceShow(_ text: String) -> HostInterfaceAddressing {
        var addressing = HostInterfaceAddressing()
        var method = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "IP4.METHOD" {
                method = value.lowercased()
                addressing.dhcpEnabled = value.lowercased() == "auto"
            } else if key.hasPrefix("IP4.ADDRESS") {
                addressing.addresses.append(
                    HostInterfaceAddressEntry(
                        cidr: value,
                        source: .static,
                        primary: addressing.addresses.isEmpty,
                    ),
                )
            } else if key == "IP4.GATEWAY" {
                addressing.gateway = value.isEmpty ? nil : value
            } else if key.hasPrefix("IP4.DNS") {
                if !value.isEmpty {
                    addressing.dns.append(value)
                }
            }
        }
        if method == "auto" {
            for index in addressing.addresses.indices {
                addressing.addresses[index].source = .dhcp
            }
        } else if !method.isEmpty, method != "manual" {
            // ignore unknown methods
        }
        return addressing
    }

    private static func netplanBlock(for interface: String, in lines: [String]) -> [String]? {
        var inSection = false
        var sectionIndent = 0
        var block: [String] = []
        for line in lines {
            let trimmed = line.trimmedHostNet
            if !inSection {
                if trimmed == "\(interface):" {
                    inSection = true
                    sectionIndent = line.prefix(while: { $0 == " " }).count
                }
                continue
            }
            if trimmed.isEmpty { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent <= sectionIndent, trimmed.hasSuffix(":"), trimmed != "\(interface):" {
                break
            }
            block.append(line)
        }
        return block.isEmpty ? nil : block
    }

    private static func parseYAMLAddressList(_ line: String) -> [String] {
        guard let open = line.firstIndex(of: "["),
              let close = line.firstIndex(of: "]"),
              open < close else {
            return []
        }
        let inner = line[line.index(after: open) ..< close]
        return inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}

extension String {
    fileprivate var trimmedHostNet: String {
        trimmingCharacters(in: .whitespaces)
    }
}

#if os(Linux)

    extension HostInterfaceAddressDiscovery {
        static func discoverLinux(
            interface: String,
            liveIPv4: [String],
            readFile: (String) -> String? = { path in
                try? String(contentsOfFile: path, encoding: .utf8)
            },
            run: (String, [String]) throws -> CommandResult = { path, args in
                try PlatformProcess.run(path: path, arguments: args, timeout: 15)
            },
        ) -> HostInterfaceAddressing {
            if let netplan = readFile(LinuxHostBridgeApply.netplanPath(bridge: interface)),
               LinuxHostInterfaceAddressRead.isBarkvisorManaged(netplan),
               let parsed = LinuxHostInterfaceAddressRead.parseNetplan(netplan, interface: interface) {
                return mergeLiveAddresses(config: parsed, liveIPv4: liveIPv4)
            }

            if let nmText = try? run("/usr/bin/nmcli", ["-t", "device", "show", interface]),
               nmText.succeeded,
               !nmText.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let config = LinuxHostInterfaceAddressRead.parseNmcliDeviceShow(nmText.stdoutString)
                return mergeLiveAddresses(config: config, liveIPv4: liveIPv4)
            }

            return fallbackFromLive(liveIPv4: liveIPv4)
        }
    }

#endif
