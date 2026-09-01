import Foundation

/// Persist `br0` on Linux via NetworkManager, netplan, or systemd-networkd.
///
/// Planner is pure (inject `LinuxHostBridgeApplyProbe`). Live apply is Linux-only
/// and never deletes a shared `br0` on revert. Guest static IPs are #385.
public enum LinuxNetworkBackend: String, Sendable, Codable, Equatable {
    case networkManager = "network-manager"
    case netplan
    case systemdNetworkd = "systemd-networkd"
    case ifupdown
    case unknown
}

public enum LinuxHostBridgeApplyAction: String, Sendable, Codable, Equatable {
    case apply
    case check
    case commit
    case dryRun = "dry-run"
    case revert
}

public enum LinuxHostBridgeAddressing: String, Sendable, Codable, Equatable {
    case dhcp
    case staticIP = "static"
}

/// Injected host view. Do not invent a second facts model — pass `HostBridgeFacts`.
public struct LinuxHostBridgeApplyProbe: Sendable, Equatable {
    public var facts: HostBridgeFacts
    public var backend: LinuxNetworkBackend
    public var wirelessNics: Set<String>
    public var sessionRiskNics: Set<String>
    public var sessionWarnings: [String]
    public var owned: Bool
    public var createdBridge: Bool
    public var existingInterfaces: Set<String>
    public var helperPaths: [String]
    public var helperSetuidPaths: Set<String>
    public var aclContents: String?
    public var listenPort: Int

    public init(
        facts: HostBridgeFacts,
        backend: LinuxNetworkBackend,
        wirelessNics: Set<String> = [],
        sessionRiskNics: Set<String> = [],
        sessionWarnings: [String] = [],
        owned: Bool = false,
        createdBridge: Bool = false,
        existingInterfaces: Set<String> = [],
        helperPaths: [String] = HostBridgeFactsService.qemuBridgeHelperCandidates,
        helperSetuidPaths: Set<String> = [],
        aclContents: String? = nil,
        listenPort: Int = 7_777,
    ) {
        self.facts = facts
        self.backend = backend
        self.wirelessNics = wirelessNics
        self.sessionRiskNics = sessionRiskNics
        self.sessionWarnings = sessionWarnings
        self.owned = owned
        self.createdBridge = createdBridge
        self.existingInterfaces = existingInterfaces
        self.helperPaths = helperPaths
        self.helperSetuidPaths = helperSetuidPaths
        self.aclContents = aclContents
        self.listenPort = listenPort
    }
}

public struct LinuxHostBridgeApplyRequest: Sendable, Equatable {
    public var action: LinuxHostBridgeApplyAction
    public var bridge: String
    public var nic: String?
    public var addressing: LinuxHostBridgeAddressing
    public var address: String?
    public var gateway: String?
    public var dns: [String]
    /// Multi-address apply (#430). When non-empty, takes precedence over `addressing` / `address`.
    public var addresses: [HostInterfaceAddressApplyEntry]
    public var confirm: Bool
    public var deleteBridge: Bool

    public init(
        action: LinuxHostBridgeApplyAction,
        bridge: String = HostBridgeFactsService.suggestedBridgeName,
        nic: String? = nil,
        addressing: LinuxHostBridgeAddressing = .dhcp,
        address: String? = nil,
        gateway: String? = nil,
        dns: [String] = [],
        addresses: [HostInterfaceAddressApplyEntry] = [],
        confirm: Bool = false,
        deleteBridge: Bool = false,
    ) {
        self.action = action
        self.bridge = bridge
        self.nic = nic
        self.addressing = addressing
        self.address = address
        self.gateway = gateway
        self.dns = dns
        self.addresses = addresses
        self.confirm = confirm
        self.deleteBridge = deleteBridge
    }
}

public struct LinuxHostBridgeApplyResult: Sendable, Equatable, Codable {
    public var success: Bool
    public var applied: Bool
    public var needsConfirm: Bool
    public var pendingCommit: Bool
    public var commitDeadline: Date?
    public var rollbackSeconds: Int?
    public var backend: String
    public var changes: [String]
    public var warnings: [String]
    public var commands: [String]
    public var message: String
    public var refused: Bool
    public var conflict: Bool

    public init(
        success: Bool,
        applied: Bool = false,
        needsConfirm: Bool = false,
        pendingCommit: Bool = false,
        commitDeadline: Date? = nil,
        rollbackSeconds: Int? = nil,
        backend: String,
        changes: [String] = [],
        warnings: [String] = [],
        commands: [String] = [],
        message: String,
        refused: Bool = false,
        conflict: Bool = false,
    ) {
        self.success = success
        self.applied = applied
        self.needsConfirm = needsConfirm
        self.pendingCommit = pendingCommit
        self.commitDeadline = commitDeadline
        self.rollbackSeconds = rollbackSeconds
        self.backend = backend
        self.changes = changes
        self.warnings = warnings
        self.commands = commands
        self.message = message
        self.refused = refused
        self.conflict = conflict
    }
}

/// Records planned writes. Live apply uses this list; tests assert it.
public struct LinuxHostBridgeChange: Sendable, Equatable {
    public var description: String
    public var command: String

    public init(description: String, command: String) {
        self.description = description
        self.command = command
    }
}

public enum LinuxHostBridgeApply {
    public static let aclMarker = "# barkvisor:allow-br0"
    public static let ownedMarkerName = "host-bridge"
    public static let rollbackSeconds = 30
    public static let netplanPath = "/etc/netplan/90-barkvisor-br0.yaml"
    public static let networkdNetdevPath = "/etc/systemd/network/90-barkvisor-br0.netdev"
    public static let networkdNetworkPath = "/etc/systemd/network/90-barkvisor-br0.network"

    public static func aclMarker(for bridge: String) -> String {
        "# barkvisor:allow-\(bridge)"
    }

    public static func netplanPath(bridge: String) -> String {
        "/etc/netplan/90-barkvisor-\(bridge).yaml"
    }

    public static func networkdNetdevPath(bridge: String) -> String {
        "/etc/systemd/network/90-barkvisor-\(bridge).netdev"
    }

    public static func networkdNetworkPath(bridge: String) -> String {
        "/etc/systemd/network/90-barkvisor-\(bridge).network"
    }

    public static func commitStampPath(bridge: String) -> String {
        "/run/barkvisor/\(bridge)-commit"
    }

    public static func createdBridge(
        named bridge: String,
        existingInterfaces: Set<String>,
        factsBridges: [HostBridgeSnapshot],
    ) -> Bool {
        !existingInterfaces.contains(bridge) && !factsBridges.contains { $0.name == bridge }
    }

    public static func nextFreeBridge(
        existingInterfaces: Set<String>,
        markerBridges: Set<String>,
    ) -> String {
        var n = 0
        while n < 1_024 {
            let name = "br\(n)"
            if !existingInterfaces.contains(name), !markerBridges.contains(name) {
                return name
            }
            n += 1
        }
        return "br0"
    }

    public static func listedMarkerBridges(dataDir: URL = Config.dataDir) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []
        let prefix = "\(ownedMarkerName)-"
        let suffix = ".json"
        var result: Set<String> = []
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let bridge = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            if !bridge.isEmpty {
                result.insert(bridge)
            }
        }
        return result
    }

    public static func nextFreeBridgeLive(
        facts: HostBridgeFacts = HostBridgeFactsService.probe(),
        dataDir: URL = Config.dataDir,
    ) -> String {
        var existing = Set(facts.bridges.map(\.name))
        existing.formUnion(existingInterfaceNames())
        return nextFreeBridge(existingInterfaces: existing, markerBridges: listedMarkerBridges(dataDir: dataDir))
    }

    public static func resolveNames(
        bodyBridge: String?,
        bodyInterface: String?,
        pathInterface: String?,
        linuxHost: Bool,
    ) -> (bridge: String, nic: String?) {
        if linuxHost {
            let bridge = bodyBridge ?? pathInterface ?? HostBridgeFactsService.suggestedBridgeName
            return (bridge, bodyInterface)
        }
        let nic = bodyInterface ?? pathInterface
        let bridge = bodyBridge ?? HostBridgeFactsService.suggestedBridgeName
        return (bridge, nic)
    }

    public static func rollbackHelperScript(bridge: String, dataDir: String) -> String {
        let stamp = commitStampPath(bridge: bridge)
        let pending = HostNetworkPendingCommitService.linuxPendingPath(bridge: bridge)
        let marker = "\(dataDir)/host-bridge-\(bridge).json"
        return """
        #!/bin/sh
        if [ -f \(stamp) ]; then exit 0; fi
        rm -f \(netplanPath(bridge: bridge)) || true
        /usr/sbin/netplan apply >/dev/null 2>&1 || true
        /usr/bin/nmcli connection delete barkvisor-\(bridge) >/dev/null 2>&1 || true
        rm -f \(networkdNetdevPath(bridge: bridge)) \(networkdNetworkPath(bridge: bridge)) || true
        /usr/bin/networkctl reload >/dev/null 2>&1 || true
        rm -f \(marker) \(pending) || true
        """
    }

    public static func evaluate(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        switch request.action {
        case .check:
            return check(request: request, probe: probe)
        case .revert:
            return revertPlan(request: request, probe: probe)
        case .commit:
            return commitPlan(request: request, probe: probe)
        case .apply, .dryRun:
            return applyPlan(request: request, probe: probe)
        }
    }

    /// Live host probe. Uses `HostBridgeFactsService` — no second facts model.
    public static func liveProbe(
        facts: HostBridgeFacts = HostBridgeFactsService.probe(),
        listenPort: Int = Config.port,
        bridge: String = HostBridgeFactsService.suggestedBridgeName,
    ) -> LinuxHostBridgeApplyProbe {
        let backend = detectBackend()
        let wireless = Set(existingInterfaceNames().filter { LinuxHostNetwork.isWirelessInterface($0) })
        let session = sessionRisk(facts: facts, listenPort: listenPort)
        let helperPaths = HostBridgeFactsService.qemuBridgeHelperCandidates.filter {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        let setuid = Set(helperPaths.filter { LinuxHostNetwork.isSetuidExecutable(at: $0) })
        let acl = try? String(
            contentsOfFile: HostBridgeFactsService.defaultACLPath,
            encoding: .utf8,
        )
        let marker = readOwnerMarker(bridge: bridge)
        return LinuxHostBridgeApplyProbe(
            facts: facts,
            backend: backend,
            wirelessNics: wireless,
            sessionRiskNics: session.nics,
            sessionWarnings: session.warnings,
            owned: marker != nil,
            createdBridge: marker?.createdBridge == true,
            existingInterfaces: Set(existingInterfaceNames()),
            helperPaths: helperPaths.isEmpty
                ? HostBridgeFactsService.qemuBridgeHelperCandidates
                : helperPaths,
            helperSetuidPaths: setuid,
            aclContents: acl,
            listenPort: listenPort,
        )
    }

    public static func detectBackend(
        netplanDir: String = "/etc/netplan",
        nmcli: String = "/usr/bin/nmcli",
        networkdRun: String = "/run/systemd/netif",
        interfacesFile: String = "/etc/network/interfaces",
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> LinuxNetworkBackend {
        if fileExists(netplanDir) {
            return .netplan
        }
        if fileExists(nmcli) {
            return .networkManager
        }
        if fileExists(networkdRun) {
            return .systemdNetworkd
        }
        if fileExists(interfacesFile) {
            return .ifupdown
        }
        return .unknown
    }

    public static func mergeACL(existing: String?, bridge: String) -> String {
        let allow = "allow \(bridge)"
        let marker = aclMarker(for: bridge)
        let current = existing ?? ""
        if LinuxHostNetwork.bridgeACLAllows(bridge, fileContents: current) {
            if current.contains(marker) {
                return current
            }
            return current.trimmingCharacters(in: .newlines) + "\n\(marker)\n"
        }
        let prefix = current.trimmingCharacters(in: .newlines)
        if prefix.isEmpty {
            return "\(marker)\n\(allow)\n"
        }
        return prefix + "\n\(marker)\n\(allow)\n"
    }

    public static func stripMarkedACL(existing: String, bridge: String) -> String {
        let marker = aclMarker(for: bridge)
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == marker {
                lines.remove(at: i)
                if i < lines.count,
                   lines[i].trimmingCharacters(in: .whitespaces) == "allow \(bridge)" {
                    lines.remove(at: i)
                }
                continue
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    public static func ownerMarkerURL(bridge: String, dataDir: URL = Config.dataDir) -> URL {
        dataDir.appendingPathComponent("\(ownedMarkerName)-\(bridge).json")
    }

    public static func netplanYAML(
        bridge: String,
        nic: String,
        addressing: LinuxHostBridgeAddressing,
        address: String?,
        gateway: String?,
        dns: [String],
    ) -> String {
        let plan: HostInterfaceAddressApplyPlan = if case let .success(resolved) = HostInterfaceAddressApply.resolveLegacy(
            addressing: addressing,
            address: address,
            gateway: gateway,
            dns: dns,
        ) {
            resolved
        } else {
            HostInterfaceAddressApplyPlan(dhcpEnabled: addressing == .dhcp, dns: dns)
        }
        return HostInterfaceAddressApply.netplanYAML(bridge: bridge, nic: nic, plan: plan)
    }

    public static func netplanYAML(
        bridge: String,
        nic: String,
        plan: HostInterfaceAddressApplyPlan,
    ) -> String {
        HostInterfaceAddressApply.netplanYAML(bridge: bridge, nic: nic, plan: plan)
    }

    // MARK: - Plan

    private static func applyPlan(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        if probe.backend == .ifupdown || probe.backend == .unknown {
            return refuse(
                backend: probe.backend,
                message: "Refuse \(probe.backend.rawValue). Persist br0 with NetworkManager, netplan, or systemd-networkd.",
            )
        }

        let nic = resolvedNic(request: request, probe: probe)
        if nic.isEmpty {
            return refuse(
                backend: probe.backend,
                message: "No wired uplink. Pass --nic or have a default route.",
            )
        }
        if !validInterfaceName(nic) {
            return refuse(backend: probe.backend, message: "Invalid interface name '\(nic)'.")
        }
        if !probe.existingInterfaces.isEmpty, !probe.existingInterfaces.contains(nic) {
            return refuse(backend: probe.backend, message: "Interface '\(nic)' is not on this Device.")
        }
        if probe.wirelessNics.contains(nic) {
            return refuse(
                backend: probe.backend,
                message: "Refuse Wi-Fi uplink '\(nic)'. Bridge a wired NIC.",
            )
        }
        if !validInterfaceName(request.bridge) {
            return refuse(backend: probe.backend, message: "Invalid bridge name '\(request.bridge)'.")
        }
        if !probe.owned, bridgeNameExists(request.bridge, probe: probe) {
            return LinuxHostBridgeApplyResult(
                success: false,
                applied: false,
                backend: probe.backend.rawValue,
                message: "Bridge '\(request.bridge)' already exists.",
                refused: true,
                conflict: true,
            )
        }
        let planResult = HostInterfaceAddressApply.resolve(from: request)
        guard case let .success(plan) = planResult else {
            if case let .failure(error) = planResult {
                return refuse(backend: probe.backend, message: error.message)
            }
            return refuse(backend: probe.backend, message: "Invalid address plan.")
        }
        _ = plan

        var warnings = probe.sessionWarnings
        if probe.facts.onlyUplink {
            warnings.append(
                "This Device has a single uplink. Enslaving it can drop SSH and the SPA. Keep changes in the SPA within \(rollbackSeconds)s or they auto-revert.",
            )
        }
        let sessionHit = probe.sessionRiskNics.contains(nic)
        if sessionHit {
            warnings.append(
                "'\(nic)' carries SSH or the SPA session. Pass --confirm. After Apply, click Keep changes within \(rollbackSeconds)s or the host auto-reverts.",
            )
        }

        let changes = plannedChanges(request: request, probe: probe, nic: nic, plan: plan)
        let commands = changes.map(\.command)
        let changeText = changes.map(\.description)

        if sessionHit || probe.facts.onlyUplink, !request.confirm {
            return LinuxHostBridgeApplyResult(
                success: false,
                applied: false,
                needsConfirm: true,
                backend: probe.backend.rawValue,
                changes: changeText,
                warnings: warnings,
                commands: commands,
                message: "Confirm required: this NIC carries SSH, the SPA, or is the only uplink.",
            )
        }

        let dry = request.action == .dryRun
        return LinuxHostBridgeApplyResult(
            success: true,
            applied: false,
            needsConfirm: false,
            backend: probe.backend.rawValue,
            changes: changeText,
            warnings: warnings,
            commands: commands,
            message: dry
                ? "Dry-run: \(changeText.count) change(s) for \(request.bridge) on \(nic)."
                : "Ready to persist \(request.bridge) on \(nic) via \(probe.backend.rawValue).",
        )
    }

    private static func revertPlan(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        if !probe.owned {
            return refuse(
                backend: probe.backend,
                message: "No BarkVisor marker for \(request.bridge). Will not delete a shared bridge.",
            )
        }
        if request.deleteBridge {
            return refuse(
                backend: probe.backend,
                message: "Refuse default-delete of \(request.bridge). Revert restores the uplink and removes BarkVisor files only.",
            )
        }
        var changes: [LinuxHostBridgeChange] = []
        switch probe.backend {
        case .netplan:
            changes.append(LinuxHostBridgeChange(
                description: "Remove \(netplanPath(bridge: request.bridge))",
                command: "sudo rm -f \(netplanPath(bridge: request.bridge)) && sudo netplan try --timeout \(rollbackSeconds)",
            ))
        case .networkManager:
            changes.append(LinuxHostBridgeChange(
                description: "Delete NetworkManager connection barkvisor-\(request.bridge)",
                command: "sudo nmcli connection delete barkvisor-\(request.bridge)",
            ))
        case .systemdNetworkd:
            changes.append(LinuxHostBridgeChange(
                description: "Remove systemd-networkd barkvisor units",
                command: "sudo rm -f \(networkdNetdevPath(bridge: request.bridge)) "
                    + "\(networkdNetworkPath(bridge: request.bridge)) && sudo networkctl reload",
            ))
        case .ifupdown, .unknown:
            return refuse(
                backend: probe.backend,
                message: "Refuse \(probe.backend.rawValue). Cannot revert a manager we do not own.",
            )
        }
        changes.append(LinuxHostBridgeChange(
            description: "Remove marker-tagged allow \(request.bridge) from \(HostBridgeFactsService.defaultACLPath)",
            command: "# strip \(aclMarker(for: request.bridge)) + allow \(request.bridge)",
        ))
        changes.append(LinuxHostBridgeChange(
            description: "Leave \(request.bridge) in place (shared bridges are never default-deleted)",
            command: "# keep \(request.bridge)",
        ))
        if probe.facts.onlyUplink || !probe.sessionRiskNics.isEmpty, !request.confirm {
            return LinuxHostBridgeApplyResult(
                success: false,
                applied: false,
                needsConfirm: true,
                backend: probe.backend.rawValue,
                changes: changes.map(\.description),
                warnings: probe.sessionWarnings + [
                    "Revert moves the Device address off \(request.bridge). Confirm before applying.",
                ],
                commands: changes.map(\.command),
                message: "Confirm required before revert.",
            )
        }
        let dry = request.action == .dryRun
        return LinuxHostBridgeApplyResult(
            success: true,
            applied: false,
            needsConfirm: false,
            backend: probe.backend.rawValue,
            changes: changes.map(\.description),
            warnings: probe.sessionWarnings,
            commands: changes.map(\.command),
            message: dry
                ? "Dry-run revert of BarkVisor \(request.bridge) files."
                : "Ready to revert BarkVisor \(request.bridge) files. \(request.bridge) stays if shared.",
        )
    }

    private static func check(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        var warnings = probe.sessionWarnings
        if probe.backend == .ifupdown || probe.backend == .unknown {
            warnings.append("Backend \(probe.backend.rawValue) is refused for apply.")
        }
        if let nic = request.nic, probe.wirelessNics.contains(nic) {
            warnings.append("Refuse Wi-Fi uplink '\(nic)'.")
        }
        let helper = probe.facts.helperPath ?? probe.helperPaths.first
        let ready = probe.facts.ready
        var changes = [
            "backend=\(probe.backend.rawValue)",
            "bridge=\(request.bridge) present=\(probe.facts.bridges.contains { $0.name == request.bridge })",
            "helper=\(helper ?? "missing") setuid=\(probe.facts.helperSetuid)",
            "acl=\(probe.facts.aclAllowsSuggested == true)",
            "owned=\(probe.owned)",
        ]
        if case let .success(plan) = HostInterfaceAddressApply.resolve(from: request) {
            let label = request.bridge
            changes += HostInterfaceAddressApply.plannedDiffs(plan: plan, interfaceLabel: label)
        }
        return LinuxHostBridgeApplyResult(
            success: ready && probe.backend != .ifupdown && probe.backend != .unknown,
            applied: false,
            backend: probe.backend.rawValue,
            changes: changes,
            warnings: warnings,
            commands: equivalentCommands(request: request, probe: probe),
            message: ready
                ? "\(request.bridge) is ready for Bridged networks."
                : "\(request.bridge) is not ready. Apply from Networks → Host interfaces.",
        )
    }

    private static func plannedChanges(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
        nic: String,
        plan: HostInterfaceAddressApplyPlan,
    ) -> [LinuxHostBridgeChange] {
        var changes: [LinuxHostBridgeChange] = []
        let addrParts = addressCLIFlags(plan: plan)
        changes.append(LinuxHostBridgeChange(
            description: "Persist \(request.bridge) via \(probe.backend.rawValue) (Device addresses on \(request.bridge), not the guest)",
            command: "POST /api/system/bridges (interface: \(nic), action: apply, confirm: true)",
        ))
        switch probe.backend {
        case .netplan:
            changes.append(LinuxHostBridgeChange(
                description: "Write \(netplanPath(bridge: request.bridge)) and `netplan try` (\(rollbackSeconds)s keep window)",
                command: "sudo netplan try --timeout \(rollbackSeconds)",
            ))
        case .networkManager:
            changes.append(LinuxHostBridgeChange(
                description: "nmcli bridge barkvisor-\(request.bridge) + systemd-run \(rollbackSeconds)s revert",
                command: "sudo nmcli connection add type bridge ifname \(request.bridge) con-name barkvisor-\(request.bridge)",
            ))
        case .systemdNetworkd:
            changes.append(LinuxHostBridgeChange(
                description: "Write \(networkdNetdevPath(bridge: request.bridge)) + systemd-run \(rollbackSeconds)s revert",
                command: "sudo networkctl reload",
            ))
        case .ifupdown, .unknown:
            break
        }
        changes.append(LinuxHostBridgeChange(
            description: "Marker-tagged allow \(request.bridge) in \(HostBridgeFactsService.defaultACLPath)",
            command: "printf '%s\\n%s\\n' '\(aclMarker(for: request.bridge))' "
                + "'allow \(request.bridge)' | sudo tee -a \(HostBridgeFactsService.defaultACLPath)",
        ))
        let helper = probe.facts.helperPath ?? probe.helperPaths.first
            ?? HostBridgeFactsService.qemuBridgeHelperCandidates[0]
        if !probe.facts.helperSetuid {
            changes.append(LinuxHostBridgeChange(
                description: "setuid qemu-bridge-helper at \(helper)",
                command: "sudo chmod u+s \(helper)",
            ))
        }
        return changes
    }

    private static func addressCLIFlags(plan: HostInterfaceAddressApplyPlan) -> String {
        var parts: [String] = []
        if plan.dhcpEnabled { parts.append("--dhcp") }
        if !plan.dhcpEnabled, plan.staticCIDRs.isEmpty == false {
            parts.append("--static")
        }
        for cidr in plan.staticCIDRs {
            parts.append("--address \(cidr)")
        }
        if let gateway = plan.gateway, !gateway.isEmpty {
            parts.append("--gateway \(gateway)")
        }
        if !plan.dns.isEmpty {
            parts.append("--dns \(plan.dns.joined(separator: ","))")
        }
        return parts.isEmpty ? "--dhcp" : parts.joined(separator: " ")
    }

    private static func equivalentCommands(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> [String] {
        let nic = resolvedNic(request: request, probe: probe)
        if nic.isEmpty {
            return ["# no wired uplink"]
        }
        guard let plan = resolvedPlan(from: request) else {
            return ["# invalid address plan"]
        }
        return plannedChanges(request: request, probe: probe, nic: nic, plan: plan).map(\.command)
    }

    private static func resolvedPlan(from request: LinuxHostBridgeApplyRequest) -> HostInterfaceAddressApplyPlan? {
        guard case let .success(plan) = HostInterfaceAddressApply.resolve(from: request) else {
            return nil
        }
        return plan
    }

    private static func resolvedNic(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> String {
        if let nic = request.nic?.trimmingCharacters(in: .whitespacesAndNewlines), !nic.isEmpty {
            return nic
        }
        return probe.facts.defaultRouteInterface ?? ""
    }

    private static func commitPlan(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        guard let pending = HostNetworkPendingCommitService.readLinux(bridge: request.bridge) else {
            return refuse(
                backend: probe.backend,
                message: "No pending host network apply for \(request.bridge).",
            )
        }
        if pending.expired {
            return refuse(
                backend: probe.backend,
                message: "Pending apply expired. Network may have auto-reverted — run Revert to clean up.",
            )
        }
        return LinuxHostBridgeApplyResult(
            success: true,
            applied: false,
            backend: probe.backend.rawValue,
            changes: ["Commit pending \(request.bridge) host network changes"],
            warnings: [],
            commands: ["# write commit stamp + SIGUSR1 netplan try"],
            message: "Ready to keep host network changes for \(request.bridge).",
        )
    }

    private static func refuse(backend: LinuxNetworkBackend, message: String) -> LinuxHostBridgeApplyResult {
        LinuxHostBridgeApplyResult(
            success: false,
            applied: false,
            backend: backend.rawValue,
            message: message,
            refused: true,
        )
    }

    private static func bridgeNameExists(_ bridge: String, probe: LinuxHostBridgeApplyProbe) -> Bool {
        probe.existingInterfaces.contains(bridge) || probe.facts.bridges.contains { $0.name == bridge }
    }

    private static func validInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count < 16, !name.contains("/"), !name.contains("\0") else {
            return false
        }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
    }

    // MARK: - Live host

    private static func existingInterfaceNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: LinuxHostNetwork.netClassPath)) ?? []
    }

    private static func sessionRisk(facts: HostBridgeFacts, listenPort: Int) -> (
        nics: Set<String>,
        warnings: [String],
    ) {
        guard let nic = facts.defaultRouteInterface, !nic.isEmpty else {
            return ([], [])
        }
        var warnings: [String] = []
        var nics = Set<String>()
        if establishedOnPort(22) {
            nics.insert(nic)
            warnings.append("SSH looks active on the default-route NIC (\(nic)).")
        }
        if listeningOnPort(listenPort) {
            nics.insert(nic)
            warnings.append("SPA/API port \(listenPort) is listening; \(nic) may carry this session.")
        }
        return (nics, warnings)
    }

    private static func establishedOnPort(_ port: Int) -> Bool {
        tcpTableHasPort(path: "/proc/net/tcp", port: port, established: true)
            || tcpTableHasPort(path: "/proc/net/tcp6", port: port, established: true)
    }

    private static func listeningOnPort(_ port: Int) -> Bool {
        tcpTableHasPort(path: "/proc/net/tcp", port: port, established: false)
            || tcpTableHasPort(path: "/proc/net/tcp6", port: port, established: false)
    }

    /// `/proc/net/tcp` hex port in column 1 (`local_address`). State 0A = LISTEN, 01 = ESTABLISHED.
    public static func tcpTableHasPort(path: String, port: Int, established: Bool) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return tcpTableHasPort(contents: text, port: port, established: established)
    }

    public static func tcpTableHasPort(contents: String, port: Int, established: Bool) -> Bool {
        let want = String(format: "%04X", port)
        let state = established ? "01" : "0A"
        for raw in contents.split(whereSeparator: \.isNewline).dropFirst() {
            let cols = raw.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 4, cols[3].uppercased() == state else { continue }
            let local = cols[1].split(separator: ":")
            let remote = cols[2].split(separator: ":")
            let localHit = local.count == 2 && local[1].uppercased() == want
            let remoteHit = established && remote.count == 2 && remote[1].uppercased() == want
            if localHit || remoteHit {
                return true
            }
        }
        return false
    }

    public struct OwnerMarker: Codable, Sendable, Equatable {
        public var bridge: String
        public var uplink: String?
        public var createdBridge: Bool

        public init(bridge: String, uplink: String? = nil, createdBridge: Bool) {
            self.bridge = bridge
            self.uplink = uplink
            self.createdBridge = createdBridge
        }
    }

    public static func readOwnerMarker(bridge: String, dataDir: URL = Config.dataDir) -> OwnerMarker? {
        let url = ownerMarkerURL(bridge: bridge, dataDir: dataDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OwnerMarker.self, from: data)
    }

    public static func writeOwnerMarker(
        bridge: String,
        uplink: String,
        createdBridge: Bool,
        dataDir: URL = Config.dataDir,
    ) throws {
        let url = ownerMarkerURL(bridge: bridge, dataDir: dataDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let marker = OwnerMarker(bridge: bridge, uplink: uplink, createdBridge: createdBridge)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: url, options: .atomic)
    }

    public static func listOwnerMarkers(dataDir: URL = Config.dataDir) -> [OwnerMarker] {
        listedMarkerBridges(dataDir: dataDir)
            .sorted()
            .compactMap { readOwnerMarker(bridge: $0, dataDir: dataDir) }
    }

    public static func createdBridgeForApply(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> Bool {
        if let marker = readOwnerMarker(bridge: request.bridge) {
            return marker.createdBridge
        }
        return createdBridge(
            named: request.bridge,
            existingInterfaces: probe.existingInterfaces,
            factsBridges: probe.facts.bridges,
        )
    }
}
