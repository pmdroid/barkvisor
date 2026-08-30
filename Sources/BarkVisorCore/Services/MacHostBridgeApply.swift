import Foundation

public enum MacHostBridgeApplyAction: String, Sendable, Codable, Equatable {
    case apply
    case check
    case dryRun = "dry-run"
    case revert
}

public enum MacHostBridgeAddressing: String, Sendable, Codable, Equatable {
    case dhcp
    case staticIP = "static"
}

public struct MacHostNetworkSnapshot: Sendable, Equatable, Codable {
    public var service: String
    public var device: String?
    public var addressing: String
    public var address: String?
    public var subnet: String?
    public var gateway: String?
    public var dns: [String]

    public init(
        service: String,
        device: String? = nil,
        addressing: String,
        address: String? = nil,
        subnet: String? = nil,
        gateway: String? = nil,
        dns: [String] = [],
    ) {
        self.service = service
        self.device = device
        self.addressing = addressing
        self.address = address
        self.subnet = subnet
        self.gateway = gateway
        self.dns = dns
    }
}

public struct MacHostBridgeApplyProbe: Sendable, Equatable {
    public var facts: HostBridgeFacts
    public var service: String?
    public var wirelessServices: Set<String>
    public var marker: MacHostNetworkSnapshot?
    public var dataDir: URL

    public init(
        facts: HostBridgeFacts,
        service: String? = nil,
        wirelessServices: Set<String> = [],
        marker: MacHostNetworkSnapshot? = nil,
        dataDir: URL = Config.dataDir,
    ) {
        self.facts = facts
        self.service = service
        self.wirelessServices = wirelessServices
        self.marker = marker
        self.dataDir = dataDir
    }
}

public struct MacHostBridgeApplyRequest: Sendable, Equatable {
    public var action: MacHostBridgeApplyAction
    public var service: String?
    public var nic: String?
    public var addressing: MacHostBridgeAddressing
    public var address: String?
    public var subnet: String?
    public var gateway: String?
    public var dns: [String]
    public var confirm: Bool

    public init(
        action: MacHostBridgeApplyAction,
        service: String? = nil,
        nic: String? = nil,
        addressing: MacHostBridgeAddressing = .dhcp,
        address: String? = nil,
        subnet: String? = nil,
        gateway: String? = nil,
        dns: [String] = [],
        confirm: Bool = false,
    ) {
        self.action = action
        self.service = service
        self.nic = nic
        self.addressing = addressing
        self.address = address
        self.subnet = subnet
        self.gateway = gateway
        self.dns = dns
        self.confirm = confirm
    }
}

public struct MacHostBridgeApplyResult: Sendable, Equatable, Codable {
    public var success: Bool
    public var applied: Bool
    public var needsConfirm: Bool
    public var backend: String
    public var changes: [String]
    public var warnings: [String]
    public var commands: [String]
    public var message: String
    public var refused: Bool

    public init(
        success: Bool,
        applied: Bool = false,
        needsConfirm: Bool = false,
        backend: String = "networksetup",
        changes: [String] = [],
        warnings: [String] = [],
        commands: [String] = [],
        message: String,
        refused: Bool = false,
    ) {
        self.success = success
        self.applied = applied
        self.needsConfirm = needsConfirm
        self.backend = backend
        self.changes = changes
        self.warnings = warnings
        self.commands = commands
        self.message = message
        self.refused = refused
    }
}

public enum MacHostBridgeApply {
    public static let backendName = "networksetup"
    public static let markerDirName = "host-network"

    public static func markerDir(dataDir: URL = Config.dataDir) -> URL {
        dataDir.appendingPathComponent(markerDirName)
    }

    public static func markerURL(service: String, dataDir: URL = Config.dataDir) -> URL {
        let safe = service.replacingOccurrences(of: "/", with: "_")
        return markerDir(dataDir: dataDir).appendingPathComponent("\(safe).json")
    }

    public static func loadMarker(service: String, dataDir: URL = Config.dataDir)
        -> MacHostNetworkSnapshot? {
        let url = markerURL(service: service, dataDir: dataDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MacHostNetworkSnapshot.self, from: data)
    }

    public static func liveProbe(
        service: String? = nil,
        nic _: String? = nil,
        facts: HostBridgeFacts? = nil,
        dataDir: URL = Config.dataDir,
    ) -> MacHostBridgeApplyProbe {
        let inputs = LiveHostBridgeFactSource().inputs()
        let assembled = facts ?? HostBridgeFactsService.assemble(from: inputs)
        let resolved = trimmed(service) ?? trimmed(inputs.hardwarePortName)
        var wireless = Set<String>()
        if let resolved, MacHostNetwork.isWirelessService(resolved) {
            wireless.insert(resolved)
        }
        return MacHostBridgeApplyProbe(
            facts: assembled,
            service: resolved,
            wirelessServices: wireless,
            marker: resolved.flatMap { loadMarker(service: $0, dataDir: dataDir) },
            dataDir: dataDir,
        )
    }

    public static func evaluate(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) -> MacHostBridgeApplyResult {
        switch request.action {
        case .check:
            return check(request: request, probe: probe)
        case .apply, .dryRun:
            return applyPlan(request: request, probe: probe)
        case .revert:
            return revertPlan(request: request, probe: probe)
        }
    }

    public static func resolvedService(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) -> String {
        trimmed(request.service) ?? trimmed(probe.service) ?? ""
    }

    public static func applyCommands(
        request: MacHostBridgeApplyRequest,
        service: String,
    ) -> [String] {
        let quoted = MacHostNetwork.quotedService(service)
        switch request.addressing {
        case .dhcp:
            return ["sudo networksetup -setdhcp \(quoted)"]
        case .staticIP:
            let parts = staticParts(request)
            return [
                "sudo networksetup -setmanual \(quoted) \(parts.ip) \(parts.mask) \(parts.gateway)",
            ]
        }
    }

    public static func revertCommands(marker: MacHostNetworkSnapshot?, service: String) -> [String] {
        let quoted = MacHostNetwork.quotedService(service)
        guard let marker else {
            return ["sudo networksetup -setdhcp \(quoted)"]
        }
        if marker.addressing == MacHostBridgeAddressing.staticIP.rawValue,
           let address = marker.address, !address.isEmpty,
           let gateway = marker.gateway, !gateway.isEmpty {
            let mask = marker.subnet ?? ipv4Mask(prefix: 24) ?? "255.255.255.0"
            let ip = splitHostAddress(address)?.ip ?? address
            return ["sudo networksetup -setmanual \(quoted) \(ip) \(mask) \(gateway)"]
        }
        return ["sudo networksetup -setdhcp \(quoted)"]
    }

    public static func splitHostAddress(_ address: String) -> (ip: String, mask: String)? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/") {
            let ip = String(trimmed[..<slash])
            let prefix = Int(trimmed[trimmed.index(after: slash)...])
            guard !ip.isEmpty, let prefix, let mask = ipv4Mask(prefix: prefix) else { return nil }
            return (ip, mask)
        }
        return (trimmed, "255.255.255.0")
    }

    public static func ipv4Mask(prefix: Int) -> String? {
        guard (0 ... 32).contains(prefix) else { return nil }
        let bits: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return [24, 16, 8, 0].map { String((bits >> $0) & 0xFF) }.joined(separator: ".")
    }

    private static func check(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) -> MacHostBridgeApplyResult {
        let service = resolvedService(request: request, probe: probe)
        var changes = [
            "service=\(service.isEmpty ? "missing" : service)",
            "ready=\(probe.facts.ready ? "yes" : "no")",
        ]
        if probe.marker != nil {
            changes.append("marker=yes")
        }
        return MacHostBridgeApplyResult(
            success: true,
            backend: backendName,
            changes: changes,
            commands: service.isEmpty ? [] : ["networksetup -getinfo \(MacHostNetwork.quotedService(service))"],
            message: service.isEmpty
                ? "No Device hardware-port service name."
                : "Device address on \(service) via \(backendName).",
        )
    }

    private static func applyPlan(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) -> MacHostBridgeApplyResult {
        let service = resolvedService(request: request, probe: probe)
        if service.isEmpty {
            return refuse(message: "Missing hardware-port service name for Device address.")
        }
        if MacHostNetwork.isWirelessService(service) || probe.wirelessServices.contains(service) {
            return refuse(message: "Refuse Wi-Fi service '\(service)'. Apply Device address on a wired port.")
        }
        if request.addressing == .staticIP {
            let parts = staticParts(request)
            if parts.ip.isEmpty {
                return refuse(
                    message: "Static host address on this Device needs --address (Device, not guest).",
                )
            }
            if parts.gateway.isEmpty {
                return refuse(message: "Static host address on this Device needs --gateway.")
            }
        }
        var warnings = [String]()
        if probe.facts.onlyUplink {
            warnings.append(
                "This Device has a single uplink. Changing its address can drop SSH and the SPA.",
            )
        }
        let commands = applyCommands(request: request, service: service)
        var changes = [
            "Capture snapshot under \(markerURL(service: service, dataDir: probe.dataDir).path)",
            request.addressing == .dhcp
                ? "Device address DHCP on \(service)"
                : "Device address static on \(service) (not the guest)",
        ]
        changes.append(contentsOf: commands)
        if probe.facts.onlyUplink, !request.confirm {
            return MacHostBridgeApplyResult(
                success: false,
                needsConfirm: true,
                backend: backendName,
                changes: changes,
                warnings: warnings,
                commands: commands,
                message: "Confirm required: this NIC is the only uplink.",
            )
        }
        let dry = request.action == .dryRun
        return MacHostBridgeApplyResult(
            success: true,
            backend: backendName,
            changes: changes,
            warnings: warnings,
            commands: commands,
            message: dry
                ? "Dry-run: Device address on \(service)."
                : "Ready to apply Device address on \(service) via \(backendName).",
        )
    }

    private static func revertPlan(
        request: MacHostBridgeApplyRequest,
        probe: MacHostBridgeApplyProbe,
    ) -> MacHostBridgeApplyResult {
        let service = resolvedService(request: request, probe: probe)
        if service.isEmpty {
            return refuse(message: "Missing hardware-port service name for Device address.")
        }
        let commands = revertCommands(marker: probe.marker, service: service)
        let viaMarker = probe.marker != nil
        let changes = [
            viaMarker
                ? "Restore Device address on \(service) from marker"
                : "No marker; fall back to DHCP on \(service)",
        ] + commands
        return MacHostBridgeApplyResult(
            success: true,
            backend: backendName,
            changes: changes,
            commands: commands,
            message: viaMarker
                ? "Ready to restore Device address on \(service)."
                : "Ready to revert Device address on \(service) to DHCP.",
        )
    }

    private static func staticParts(_ request: MacHostBridgeApplyRequest) -> (
        ip: String,
        mask: String,
        gateway: String,
    ) {
        let parsed = request.address.flatMap(splitHostAddress)
        let ip = parsed?.ip ?? trimmed(request.address) ?? ""
        let mask = trimmed(request.subnet) ?? parsed?.mask ?? ipv4Mask(prefix: 24) ?? "255.255.255.0"
        let gateway = trimmed(request.gateway) ?? ""
        return (ip, mask, gateway)
    }

    private static func refuse(message: String) -> MacHostBridgeApplyResult {
        MacHostBridgeApplyResult(
            success: false,
            backend: backendName,
            message: message,
            refused: true,
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

public typealias MacHostNetworkApply = MacHostBridgeApply
