import Foundation

/// Apply-time address entry for host interface / bridge (#430).
public enum HostInterfaceAddressApplyKind: String, Sendable, Codable, Equatable {
    case dhcp
    case `static`
    case alias
}

public struct HostInterfaceAddressApplyEntry: Sendable, Codable, Equatable {
    public var kind: HostInterfaceAddressApplyKind
    public var cidr: String?
    public var gateway: String?
    public var dns: [String]?

    public init(
        kind: HostInterfaceAddressApplyKind,
        cidr: String? = nil,
        gateway: String? = nil,
        dns: [String]? = nil,
    ) {
        self.kind = kind
        self.cidr = cidr
        self.gateway = gateway
        self.dns = dns
    }
}

/// Normalized multi-address plan for Linux netplan/NM and macOS networksetup/ifconfig.
public struct HostInterfaceAddressApplyPlan: Sendable, Equatable {
    public var dhcpEnabled: Bool
    /// Static CIDRs on the interface (primary static first, then aliases).
    public var staticCIDRs: [String]
    public var gateway: String?
    public var dns: [String]

    public init(
        dhcpEnabled: Bool = false,
        staticCIDRs: [String] = [],
        gateway: String? = nil,
        dns: [String] = [],
    ) {
        self.dhcpEnabled = dhcpEnabled
        self.staticCIDRs = staticCIDRs
        self.gateway = gateway
        self.dns = dns
    }

    public var primaryStaticCIDR: String? {
        staticCIDRs.first
    }
    public var aliasCIDRs: [String] {
        dhcpEnabled ? staticCIDRs : Array(staticCIDRs.dropFirst())
    }

    /// Legacy single-mode view for callers not yet on `addresses[]`.
    public var legacyAddressing: LinuxHostBridgeAddressing {
        if dhcpEnabled, staticCIDRs.isEmpty { return .dhcp }
        return .staticIP
    }

    public var legacyAddress: String? {
        primaryStaticCIDR
    }
}

public enum HostInterfaceAddressApplyError: Error, Equatable, Sendable {
    case invalid(String)

    public var message: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

public enum HostInterfaceAddressApply {
    /// Build a normalized plan from the apply request (legacy fields or `addresses[]`).
    public static func resolve(
        from request: LinuxHostBridgeApplyRequest,
    ) -> Result<HostInterfaceAddressApplyPlan, HostInterfaceAddressApplyError> {
        if !request.addresses.isEmpty {
            return resolveFromAddresses(
                request.addresses,
                fallbackGateway: request.gateway,
                fallbackDNS: request.dns,
            )
        }
        return resolveLegacy(
            addressing: request.addressing,
            address: request.address,
            gateway: request.gateway,
            dns: request.dns,
        )
    }

    public static func resolveFromAddresses(
        _ entries: [HostInterfaceAddressApplyEntry],
        fallbackGateway: String?,
        fallbackDNS: [String],
    ) -> Result<HostInterfaceAddressApplyPlan, HostInterfaceAddressApplyError> {
        var dhcpEnabled = false
        var staticCIDRs: [String] = []
        var gateway = trimmed(fallbackGateway)
        var dns = fallbackDNS.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        for entry in entries {
            switch entry.kind {
            case .dhcp:
                dhcpEnabled = true
            case .static, .alias:
                guard let raw = entry.cidr?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return .failure(.invalid("\(entry.kind.rawValue) address needs cidr (e.g. 192.168.1.10/24)."))
                }
                guard validCIDR(raw) else {
                    return .failure(.invalid("Invalid CIDR '\(raw)'."))
                }
                if staticCIDRs.contains(raw) {
                    return .failure(.invalid("Duplicate address \(raw)."))
                }
                staticCIDRs.append(raw)
                if entry.kind == .static, gateway == nil {
                    gateway = trimmed(entry.gateway)
                }
                if let rowDNS = entry.dns, !rowDNS.isEmpty, dns.isEmpty {
                    dns = rowDNS.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
            }
        }

        if !dhcpEnabled, staticCIDRs.isEmpty {
            return .failure(.invalid("At least one address source (DHCP or static) is required."))
        }
        if !dhcpEnabled, gateway == nil {
            return .failure(.invalid("Static host address on Device needs gateway."))
        }
        return .success(
            HostInterfaceAddressApplyPlan(
                dhcpEnabled: dhcpEnabled,
                staticCIDRs: staticCIDRs,
                gateway: gateway,
                dns: dns,
            ),
        )
    }

    public static func resolveLegacy(
        addressing: LinuxHostBridgeAddressing,
        address: String?,
        gateway: String?,
        dns: [String],
    ) -> Result<HostInterfaceAddressApplyPlan, HostInterfaceAddressApplyError> {
        switch addressing {
        case .dhcp:
            return .success(HostInterfaceAddressApplyPlan(dhcpEnabled: true, dns: dns))
        case .staticIP:
            guard let raw = trimmed(address), !raw.isEmpty else {
                return .failure(.invalid("Static host address on Device needs address (e.g. 192.168.1.10/24)."))
            }
            guard validCIDR(raw) else {
                return .failure(.invalid("Invalid CIDR '\(raw)'."))
            }
            guard let gw = trimmed(gateway), !gw.isEmpty else {
                return .failure(.invalid("Static host address needs gateway."))
            }
            return .success(
                HostInterfaceAddressApplyPlan(
                    dhcpEnabled: false,
                    staticCIDRs: [raw],
                    gateway: gw,
                    dns: dns,
                ),
            )
        }
    }

    /// Human-readable diffs for `action: check` / dry-run (#430).
    public static func plannedDiffs(
        plan: HostInterfaceAddressApplyPlan,
        interfaceLabel: String,
    ) -> [String] {
        var lines: [String] = []
        if plan.dhcpEnabled {
            lines.append("Set \(interfaceLabel) IPv4: DHCP (primary)")
        }
        if let primary = plan.primaryStaticCIDR, !plan.dhcpEnabled {
            lines.append("Set \(interfaceLabel) IPv4: static \(primary)")
        } else if let primary = plan.primaryStaticCIDR, plan.dhcpEnabled {
            lines.append("Add \(interfaceLabel) static alias \(primary)")
        }
        for alias in plan.aliasCIDRs {
            lines.append("Add \(interfaceLabel) static alias \(alias)")
        }
        if let gateway = plan.gateway, !gateway.isEmpty {
            lines.append("Default route gateway: \(gateway)")
        }
        if !plan.dns.isEmpty {
            lines.append("DNS: \(plan.dns.joined(separator: ", "))")
        }
        return lines
    }

    public static func netplanAddressesYAML(_ cidrs: [String]) -> String {
        guard !cidrs.isEmpty else { return "" }
        if cidrs.count == 1 {
            return "      addresses: [\(cidrs[0])]\n"
        }
        var body = "      addresses:\n"
        for cidr in cidrs {
            body += "        - \(cidr)\n"
        }
        return body
    }

    public static func netplanYAML(
        bridge: String,
        nic: String,
        plan: HostInterfaceAddressApplyPlan,
    ) -> String {
        var body = """
        # managed-by: barkvisor
        network:
          version: 2
          renderer: networkd
          ethernets:
            \(nic):
              dhcp4: false
          bridges:
            \(bridge):
              interfaces: [\(nic)]

        """
        if plan.dhcpEnabled {
            body += "      dhcp4: true\n"
        }
        if !plan.staticCIDRs.isEmpty {
            body += netplanAddressesYAML(plan.staticCIDRs)
        }
        if let gateway = plan.gateway, !gateway.isEmpty, !plan.dhcpEnabled {
            body += """
                  routes:
                    - to: default
                      via: \(gateway)

            """
        }
        if !plan.dns.isEmpty {
            body += """
                  nameservers:
                    addresses: [\(plan.dns.joined(separator: ", "))]

            """
        }
        return body
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func validCIDR(_ raw: String) -> Bool {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let prefix = Int(parts[1]), (1 ... 32).contains(prefix) else {
            return false
        }
        let octets = parts[0].split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { Int($0).map { (0 ... 255).contains($0) } == true }
    }
}
