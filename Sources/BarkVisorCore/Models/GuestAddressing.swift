import Foundation

/// Guest LAN addressing for a bridged Workload. Host `br0` is #378 — not this type.
///
/// Default is DHCP (omit, or `mode: dhcp`). Static IPv4 is applied only via
/// NoCloud `network-config` on a cloud-init ISO — never on NAT or isolated.
public struct GuestAddressing: Codable, Equatable, Sendable {
    public static let modeDHCP = "dhcp"
    public static let modeStatic = "static"

    public var mode: String
    public var ipv4: String?
    public var prefixLength: Int?
    public var gateway: String?
    public var nameservers: [String]?

    public init(
        mode: String,
        ipv4: String? = nil,
        prefixLength: Int? = nil,
        gateway: String? = nil,
        nameservers: [String]? = nil,
    ) {
        self.mode = mode
        self.ipv4 = ipv4
        self.prefixLength = prefixLength
        self.gateway = gateway
        self.nameservers = nameservers
    }

    public static var dhcp: GuestAddressing {
        GuestAddressing(mode: modeDHCP)
    }

    public var isDHCP: Bool {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == Self.modeDHCP
    }

    public var isStatic: Bool {
        mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.modeStatic
    }

    /// Stable token for cloud-init `instance-id` so a change re-applies next boot.
    public var instanceToken: String {
        if isDHCP { return Self.modeDHCP }
        let dns = (nameservers ?? []).joined(separator: ",")
        let canonical = [
            Self.modeStatic,
            ipv4 ?? "",
            String(prefixLength ?? 0),
            gateway ?? "",
            dns,
        ].joined(separator: "|")
        return "s\(Self.djb2Hex(canonical))"
    }

    public func validated() throws -> GuestAddressing {
        let trimmedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedMode == Self.modeDHCP || trimmedMode == Self.modeStatic else {
            throw BarkVisorError.badRequest("guestAddressing.mode must be dhcp or static")
        }
        if trimmedMode == Self.modeDHCP {
            return GuestAddressing(mode: Self.modeDHCP)
        }
        let ip = ipv4?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gw = gateway?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ip.isEmpty else {
            throw BarkVisorError.badRequest("Static addressing requires ipv4")
        }
        guard !gw.isEmpty else {
            throw BarkVisorError.badRequest("Static addressing requires gateway")
        }
        try validateIPv4(ip, label: "guestAddressing.ipv4")
        try validateIPv4(gw, label: "guestAddressing.gateway")
        try Self.rejectUnusable(ip, label: "guestAddressing.ipv4")
        try Self.rejectUnusable(gw, label: "guestAddressing.gateway")
        guard let prefix = prefixLength, (1 ... 32).contains(prefix) else {
            throw BarkVisorError.badRequest("guestAddressing.prefixLength must be 1...32")
        }
        var dns: [String] = []
        for server in nameservers ?? [] {
            let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try validateIPv4(trimmed, label: "guestAddressing.nameservers")
            dns.append(trimmed)
        }
        return GuestAddressing(
            mode: Self.modeStatic,
            ipv4: ip,
            prefixLength: prefix,
            gateway: gw,
            nameservers: dns.isEmpty ? nil : dns,
        )
    }

    /// Static IPv4 is cloud-init on a bridged Workload only. NAT uses port forwards.
    public static func require(
        _ addressing: GuestAddressing?,
        networkMode: NetworkMode,
        cloudInitApplies: Bool,
    ) throws -> GuestAddressing? {
        guard let addressing else { return nil }
        let valid = try addressing.validated()
        guard valid.isStatic else { return valid }
        guard networkMode == .bridged else {
            throw BarkVisorError.badRequest(
                "Static addressing is only for bridged Workloads. NAT uses port forwards; isolated stays private.",
            )
        }
        guard cloudInitApplies else {
            throw BarkVisorError.badRequest(
                "Static addressing needs a cloud-init image. Installer ISOs: set the address in the guest or on the router.",
            )
        }
        return valid
    }

    /// NoCloud network-config v2. Nil when DHCP (guest uses LAN DHCP).
    public func networkConfigYAML(macAddress: String?) throws -> String? {
        let valid = try validated()
        guard valid.isStatic, let ip = valid.ipv4, let prefix = valid.prefixLength, let gw = valid.gateway
        else { return nil }

        var lines = [
            "version: 2",
            "ethernets:",
            "  id0:",
        ]
        if let mac = Self.normalizedMAC(macAddress) {
            lines += [
                "    match:",
                "      macaddress: \"\(mac)\"",
                "    set-name: eth0",
            ]
        }
        lines += [
            "    dhcp4: false",
            "    addresses:",
            "      - \(ip)/\(prefix)",
            "    routes:",
            "      - to: default",
            "        via: \(gw)",
        ]
        if let dns = valid.nameservers, !dns.isEmpty {
            lines += [
                "    nameservers:",
                "      addresses:",
            ]
            lines += dns.map { "        - \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func composeInstanceID(base: String, addressing: GuestAddressing?) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "cidata" : trimmed
        guard let addressing else { return resolved }
        return "\(resolved)-net-\(addressing.instanceToken)"
    }

    public static func cloudInitApplies(
        cloudImageId: String?,
        isoId: String?,
        sshKeys: [String],
        userData: String?,
        existingCloudInitPath: String? = nil,
    ) -> Bool {
        if let existing = existingCloudInitPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return true
        }
        let keys = sshKeys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let extra = userData?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !keys.isEmpty || !extra.isEmpty { return true }
        // Cloud images run cloud-init; a seed ISO is written when static addressing is set.
        if let image = cloudImageId?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            return true
        }
        _ = isoId
        return false
    }

    private static func rejectUnusable(_ ip: String, label: String) throws {
        if ip == "0.0.0.0" || ip == "255.255.255.255" {
            throw BarkVisorError.badRequest("\(label) is not a usable guest address")
        }
    }

    private static func normalizedMAC(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func djb2Hex(_ value: String) -> String {
        var hash: UInt64 = 5_381
        for byte in value.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
