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
    case delete
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
    public var liveIPv4CIDRs: [String]
    public var keepIPv4CIDRs: [String]

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
        liveIPv4CIDRs: [String] = [],
        keepIPv4CIDRs: [String] = [],
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
        self.liveIPv4CIDRs = liveIPv4CIDRs
        self.keepIPv4CIDRs = keepIPv4CIDRs
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
    public var attachedWorkloadCount: Int

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
        attachedWorkloadCount: Int = 0,
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
        self.attachedWorkloadCount = attachedWorkloadCount
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
    public var createdBridge: Bool

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
        createdBridge: Bool = false,
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
        self.createdBridge = createdBridge
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
    public static let rollbackSeconds = 60

    public static func dropsManagementSession(
        nic: String,
        probe: LinuxHostBridgeApplyProbe,
    ) -> Bool {
        if probe.sessionRiskNics.contains(nic) { return true }
        return probe.facts.onlyUplink
    }
    public static let netplanPath = "/etc/netplan/90-barkvisor-br0.yaml"
    public static let networkdNetdevPath = "/etc/systemd/network/90-barkvisor-br0.netdev"
    public static let networkdNetworkPath = "/etc/systemd/network/90-barkvisor-br0.network"

    public static func aclMarker(for bridge: String) -> String {
        "# barkvisor:allow-\(bridge)"
    }

    public static func aclTagged(bridge: String, acl: String?) -> Bool {
        let name = bridge.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let acl, !name.isEmpty else { return false }
        return acl.contains(aclMarker(for: name))
    }

    public static func leftoverHostBridge(
        bridge: String,
        dir: String = systemdNetworkDir,
    ) -> Bool {
        let persist = systemdBridgePersist(bridge: bridge, dir: dir)
        return !persist.remove.isEmpty || !persist.rewrite.isEmpty
    }

    public static func ownership(
        bridge: String,
        marker: OwnerMarker?,
        acl: String?,
        leftoverPersist: Bool = false,
    ) -> (owned: Bool, createdBridge: Bool) {
        let tagged = aclTagged(bridge: bridge, acl: acl)
        let leftover = leftoverPersist
        return (
            owned: marker != nil || tagged || leftover,
            createdBridge: marker?.createdBridge == true || (marker == nil && (tagged || leftover)),
        )
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

    public static func networkdPortPath(nic: String) -> String {
        "/etc/systemd/network/90-barkvisor-\(nic).network"
    }

    public static func nmSlaveConnectionName(bridge: String, nic: String) -> String {
        "barkvisor-\(bridge)-\(nic)"
    }

    public static let systemdNetworkDir = "/etc/systemd/network"

    public struct SystemdBridgePersist: Sendable, Equatable {
        public var remove: [String]
        public var rewrite: [String]

        public init(remove: [String] = [], rewrite: [String] = []) {
            self.remove = remove
            self.rewrite = rewrite
        }
    }

    public static func systemdBridgePersist(
        bridge: String,
        dir: String = systemdNetworkDir,
    ) -> SystemdBridgePersist {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var remove: [String] = []
        var rewrite: [String] = []
        for name in names.sorted() {
            let path = "\(dir)/\(name)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if name.hasSuffix(".netdev"),
               hasNetworkAssignment(text, key: "Name", value: bridge),
               hasNetworkAssignment(text, key: "Kind", value: "bridge") {
                remove.append(path)
            } else if name.hasSuffix(".network"), hasNetworkAssignment(text, key: "Bridge", value: bridge) {
                rewrite.append(path)
            } else if name.hasSuffix(".network"),
                      hasNetworkAssignment(text, key: "Name", value: bridge) {
                remove.append(path)
            }
        }
        return SystemdBridgePersist(remove: remove, rewrite: rewrite)
    }

    public static func rewritePortNetworkDroppingBridge(_ text: String, bridge: String, cidrs: [String]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == "Bridge=\(bridge)" }
        let hasAddress = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Address=") }
        if !hasAddress {
            for cidr in cidrs {
                lines.append("Address=\(cidr)")
            }
        }
        let hasDHCP = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("DHCP=") }
        if !hasDHCP, !cidrs.isEmpty {
            lines.append("DHCP=yes")
        }
        var body = lines.joined(separator: "\n")
        if !body.hasSuffix("\n") { body += "\n" }
        return body
    }

    public static func hasNetworkAssignment(_ text: String, key: String, value: String) -> Bool {
        let want = "\(key)=\(value)"
        for raw in text.split(whereSeparator: \.isNewline) {
            if raw.trimmingCharacters(in: .whitespaces) == want { return true }
        }
        return false
    }

    public static func commitStampPath(bridge: String, dataDir: URL = Config.dataDir) -> String {
        dataDir.appendingPathComponent("host-network", isDirectory: true)
            .appendingPathComponent("\(bridge)-commit").path
    }

    public enum NetplanExpireAction: String, Sendable, Equatable {
        case waitForTry
        case stampKeep
        case alreadyReverted
    }

    public static func netplanExpireAction(
        pidAlive: Bool,
        pidIsNetplan: Bool,
        keeping: Bool,
    ) -> NetplanExpireAction {
        if pidAlive, pidIsNetplan { return .waitForTry }
        if keeping { return .stampKeep }
        return .alreadyReverted
    }

    public static func shouldDeleteWorkloadNetwork(createdBridge: Bool, attached: Int) -> Bool {
        createdBridge && attached == 0
    }

    public static func isNetplanProcess(pid: Int32) -> Bool {
        isNetplanProcess(pid: pid) { candidate in
            try? String(contentsOfFile: "/proc/\(candidate)/cmdline", encoding: .utf8)
        }
    }

    public static func isNetplanProcess(pid: Int32, readCmdline: (Int32) -> String?) -> Bool {
        let text = readCmdline(pid)?.replacingOccurrences(of: "\0", with: " ") ?? ""
        return text.contains("netplan")
    }

    public static func rollbackClaimShell(claim: String, stamp: String, keeping: String) -> String {
        """
        if [ -f \(stamp) ]; then exit 0; fi
        if [ -f \(keeping) ]; then exit 0; fi
        if ! mkdir \(claim) 2>/dev/null; then
          if [ -f \(stamp) ]; then exit 0; fi
          if [ -f \(keeping) ]; then exit 0; fi
          age=$(stat -c %Y \(claim) 2>/dev/null || echo 0)
          now=$(date +%s)
          if [ $((now - age)) -lt 30 ]; then exit 0; fi
          rm -rf \(claim)
          mkdir \(claim) 2>/dev/null || exit 0
        fi
        if [ -f \(stamp) ]; then rmdir \(claim) 2>/dev/null; exit 0; fi
        if [ -f \(keeping) ]; then rmdir \(claim) 2>/dev/null; exit 0; fi
        """
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
        extraTaken: Set<String> = [],
    ) -> String {
        var existing = Set(facts.bridges.map(\.name))
        existing.formUnion(existingInterfaceNames())
        existing.formUnion(extraTaken)
        return nextFreeBridge(existingInterfaces: existing, markerBridges: listedMarkerBridges(dataDir: dataDir))
    }

    public static func resolveNames(
        bodyBridge: String?,
        bodyInterface: String?,
        pathInterface: String?,
        linuxHost: Bool,
    ) -> (bridge: String, nic: String?) {
        if linuxHost {
            let bridge = bodyBridge ?? pathInterface ?? ""
            return (bridge, bodyInterface)
        }
        let nic = bodyInterface ?? pathInterface
        let bridge = bodyBridge ?? ""
        return (bridge, nic)
    }

    public static func rollbackHelperScript(bridge: String, dataDir: String) -> String {
        let stamp = commitStampPath(bridge: bridge)
        let pending = HostNetworkPendingCommitService.linuxPendingPath(bridge: bridge)
        let claim = HostNetworkPendingCommitService.claimPath(bridge)
        let keeping = HostNetworkPendingCommitService.keepingPath(bridge)
        let marker = "\(dataDir)/host-bridge-\(bridge).json"
        return """
        #!/bin/sh
        \(rollbackClaimShell(claim: claim, stamp: stamp, keeping: keeping))
        rm -f \(netplanPath(bridge: bridge)) || true
        /usr/sbin/netplan apply >/dev/null 2>&1 || true
        /usr/bin/nmcli connection delete barkvisor-\(bridge) >/dev/null 2>&1 || true
        /usr/bin/nmcli -t -f NAME connection show 2>/dev/null | grep "^barkvisor-\(bridge)-" | while read -r n; do
          /usr/bin/nmcli connection delete "$n" >/dev/null 2>&1 || true
        done
        rm -f \(networkdNetdevPath(bridge: bridge)) \(networkdNetworkPath(bridge: bridge)) || true
        uplink=$(sed -n 's/.*"uplink"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' \(marker) 2>/dev/null | head -1)
        if [ -n "$uplink" ]; then
          rm -f /etc/systemd/network/90-barkvisor-"$uplink".network || true
          /usr/bin/nmcli device reapply "$uplink" >/dev/null 2>&1 || true
          /usr/bin/networkctl reapply "$uplink" >/dev/null 2>&1 || true
        fi
        /usr/bin/networkctl reload >/dev/null 2>&1 || true
        if grep -q '"createdBridge"[[:space:]]*:[[:space:]]*true' \(pending) 2>/dev/null; then
          /sbin/ip link del \(bridge) >/dev/null 2>&1 || /usr/sbin/ip link del \(bridge) >/dev/null 2>&1 || true
        fi
        rm -f \(marker) \(pending) || true
        rmdir \(claim) 2>/dev/null || true
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
        case .delete:
            return deletePlan(request: request, probe: probe)
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
        nic: String? = nil,
    ) -> LinuxHostBridgeApplyProbe {
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
        let claim = ownership(
            bridge: bridge,
            marker: marker,
            acl: acl,
            leftoverPersist: leftoverHostBridge(bridge: bridge),
        )
        let target = (nic ?? facts.defaultRouteInterface ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = target.isEmpty
            ? detectBackend()
            : detectActiveBackend(nic: target)
        var liveIPv4: [String] = []
        var keepIPv4: [String] = []
        if !target.isEmpty {
            let addressing = HostInterfaceAddressDiscovery.discoverByInterface(interfaceNames: [target])[target]
            liveIPv4 = addressing?.addresses.map(\.cidr) ?? []
            keepIPv4 = addressing?.addresses.filter { $0.source == .dhcp }.map(\.cidr) ?? []
            if keepIPv4.isEmpty {
                let kernel = HostInfoService.listInterfaceAddresses().first { row in
                    row.name == target && !row.ipAddress.contains(":")
                }
                if let kernel {
                    let cidr = kernel.prefixLength.map { "\(kernel.ipAddress)/\($0)" } ?? kernel.ipAddress
                    keepIPv4 = [cidr]
                }
            }
        }
        return LinuxHostBridgeApplyProbe(
            facts: facts,
            backend: backend,
            wirelessNics: wireless,
            sessionRiskNics: session.nics,
            sessionWarnings: session.warnings,
            owned: claim.owned,
            createdBridge: claim.createdBridge,
            existingInterfaces: Set(existingInterfaceNames()),
            helperPaths: helperPaths.isEmpty
                ? HostBridgeFactsService.qemuBridgeHelperCandidates
                : helperPaths,
            helperSetuidPaths: setuid,
            aclContents: acl,
            listenPort: listenPort,
            liveIPv4CIDRs: liveIPv4,
            keepIPv4CIDRs: keepIPv4,
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

    public static func detectActiveBackend(
        nic: String,
        nmManaged: Bool? = nil,
        networkdManages: Bool? = nil,
        installed: () -> LinuxNetworkBackend = { detectBackend() },
    ) -> LinuxNetworkBackend {
        let nm = nmManaged ?? nicManagedByNetworkManager(nic)
        if nm == true { return .networkManager }
        let networkd = networkdManages ?? nicManagedByNetworkd(nic)
        if networkd == true { return .systemdNetworkd }
        return installed()
    }

    public static func nicManagedByNetworkManager(_ nic: String) -> Bool? {
        let name = nic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/nmcli") else { return nil }
        let result = try? PlatformProcess.run(
            path: "/usr/bin/nmcli",
            arguments: ["-g", "GENERAL.NM-MANAGED", "device", "show", name],
            timeout: 5,
        )
        guard let result, result.succeeded else { return nil }
        switch result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    public static func nicManagedByNetworkd(_ nic: String) -> Bool? {
        let name = nic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let path = ["/usr/bin/networkctl", "/bin/networkctl"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let path else { return nil }
        let result = try? PlatformProcess.run(
            path: path,
            arguments: ["status", name],
            timeout: 5,
        )
        guard let result, result.succeeded else { return nil }
        let text = result.stdoutString.lowercased()
        if text.contains("unmanaged") { return false }
        return true
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
        if isAddressOnlyApply(request: request, probe: probe) {
            return addressOnlyPlan(request: request, probe: probe)
        }
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
                "This Device has a single uplink. Enslaving it can drop SSH and the SPA. Keep changes within \(rollbackSeconds)s or they auto-revert.",
            )
        }
        let sessionHit = probe.sessionRiskNics.contains(nic)
        if sessionHit {
            warnings.append(
                "'\(nic)' carries SSH or the SPA session. Pass --confirm. Keep changes within \(rollbackSeconds)s or they auto-revert.",
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

    private static func addressOnlyPlan(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        let nic = resolvedNic(request: request, probe: probe)
        if nic.isEmpty {
            return refuse(
                backend: probe.backend,
                message: "No interface. Select a NIC.",
            )
        }
        if !validInterfaceName(nic) {
            return refuse(backend: probe.backend, message: "Invalid interface name '\(nic)'.")
        }
        if !probe.existingInterfaces.isEmpty, !probe.existingInterfaces.contains(nic) {
            return refuse(backend: probe.backend, message: "Interface '\(nic)' is not on this Device.")
        }
        let planResult = HostInterfaceAddressApply.resolve(from: request)
        guard case let .success(plan) = planResult else {
            if case let .failure(error) = planResult {
                return refuse(backend: probe.backend, message: error.message)
            }
            return refuse(backend: probe.backend, message: "Invalid address plan.")
        }
        let target = addressApplyDevice(request: request, probe: probe)
        let changes = addressOnlyChanges(
            target: target,
            plan: plan,
            backend: probe.backend,
            liveCIDRs: probe.liveIPv4CIDRs,
            keepCIDRs: probe.keepIPv4CIDRs,
        )
        let dry = request.action == .dryRun
        return LinuxHostBridgeApplyResult(
            success: true,
            applied: false,
            needsConfirm: false,
            backend: probe.backend.rawValue,
            changes: changes.map(\.description),
            warnings: [],
            commands: changes.map(\.command).filter { !$0.isEmpty },
            message: dry
                ? "Dry run: Device address apply plan."
                : "Apply Device addresses on \(target).",
        )
    }

    private static func revertPlan(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        if isAddressOnlyApply(request: request, probe: probe), !probe.owned {
            let target = addressApplyDevice(request: request, probe: probe)
            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                needsConfirm: false,
                backend: probe.backend.rawValue,
                changes: ["Remove BarkVisor-owned extra addresses on \(target)"],
                warnings: [],
                commands: ["sudo /run/barkvisor/\(target)-rollback.sh"],
                message: "Revert BarkVisor-owned Device addresses. Bridge stays.",
            )
        }
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
            let nic = resolvedNic(request: request, probe: probe)
            changes.append(LinuxHostBridgeChange(
                description: "Delete NetworkManager connection barkvisor-\(request.bridge)",
                command: "sudo nmcli connection delete barkvisor-\(request.bridge)",
            ))
            if !nic.isEmpty {
                changes.append(LinuxHostBridgeChange(
                    description: "Delete NetworkManager slave \(nmSlaveConnectionName(bridge: request.bridge, nic: nic))",
                    command: "sudo nmcli connection delete \(nmSlaveConnectionName(bridge: request.bridge, nic: nic))",
                ))
                changes.append(LinuxHostBridgeChange(
                    description: "Restore L3 on \(nic)",
                    command: "sudo nmcli device reapply \(nic)",
                ))
            }
        case .systemdNetworkd:
            let nic = resolvedNic(request: request, probe: probe)
            var units = "\(networkdNetdevPath(bridge: request.bridge)) \(networkdNetworkPath(bridge: request.bridge))"
            if !nic.isEmpty {
                units += " \(networkdPortPath(nic: nic))"
            }
            changes.append(LinuxHostBridgeChange(
                description: "Remove systemd-networkd barkvisor units",
                command: "sudo rm -f \(units) && sudo networkctl reload",
            ))
            if !nic.isEmpty {
                changes.append(LinuxHostBridgeChange(
                    description: "Restore L3 on \(nic)",
                    command: "sudo networkctl reapply \(nic)",
                ))
            }
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
        changes.append(LinuxHostBridgeChange(
            description: "Persist \(request.bridge) via \(probe.backend.rawValue) (Device addresses on \(request.bridge), not the guest)",
            command: "POST /api/system/interfaces (interface: \(nic), action: apply, confirm: true)",
        ))
        switch probe.backend {
        case .netplan:
            changes.append(LinuxHostBridgeChange(
                description: "Write \(netplanPath(bridge: request.bridge)) and `netplan try` (\(rollbackSeconds)s keep window)",
                command: "sudo netplan try --timeout \(rollbackSeconds)",
            ))
        case .networkManager:
            let slave = nmSlaveConnectionName(bridge: request.bridge, nic: nic)
            changes.append(LinuxHostBridgeChange(
                description: "nmcli bridge barkvisor-\(request.bridge) + systemd-run \(rollbackSeconds)s revert",
                command: "sudo nmcli connection add type bridge ifname \(request.bridge) con-name barkvisor-\(request.bridge)",
            ))
            changes.append(LinuxHostBridgeChange(
                description: "Attach \(nic) as bridge port",
                command: "sudo nmcli connection add type bridge-slave ifname \(nic) master \(request.bridge) con-name \(slave)",
            ))
            changes.append(LinuxHostBridgeChange(
                description: "Bring up \(request.bridge) and \(nic)",
                command: "sudo nmcli connection up barkvisor-\(request.bridge) && sudo nmcli connection up \(slave)",
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
        return plannedChanges(
            request: request,
            probe: probe,
            nic: nic,
            plan: plan,
        ).map(\.command)
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

    // MARK: - Live host

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

    public static func isAddressOnlyApply(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> Bool {
        let bridge = request.bridge.trimmingCharacters(in: .whitespacesAndNewlines)
        if bridge.isEmpty { return true }
        if probe.owned { return false }
        let nic = resolvedNic(request: request, probe: probe)
        if nic == bridge { return true }
        return probe.facts.bridges.contains { $0.name == bridge && $0.enslaved.contains(nic) }
    }

    public static func addressApplyDevice(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> String {
        let nic = resolvedNic(request: request, probe: probe)
        if let master = probe.facts.bridges.first(where: { $0.enslaved.contains(nic) }) {
            return master.name
        }
        return nic
    }

    public static func addressOnlyChanges(
        target: String,
        plan: HostInterfaceAddressApplyPlan,
        backend: LinuxNetworkBackend = .netplan,
        liveCIDRs: [String] = [],
        keepCIDRs: [String] = [],
    ) -> [LinuxHostBridgeChange] {
        let cidrs = plan.dhcpEnabled ? plan.staticCIDRs : plan.aliasCIDRs
        return LinuxHostAddressPersist.previewCommands(
            interface: target,
            cidrs: cidrs,
            backend: backend,
            liveCIDRs: liveCIDRs,
            keepCIDRs: keepCIDRs,
        )
    }

    public static func addressRollbackHelperScript(
        device: String,
        iface: String,
        cidrs: [String],
        persistFiles: [String] = [],
        restoreCIDRs: [String] = [],
        persistRestore: [(path: String, previous: String?)] = [],
        nmConnection: String = "",
    ) -> String {
        let stamp = commitStampPath(bridge: device)
        let pending = HostNetworkPendingCommitService.linuxPendingPath(bridge: device)
        let claim = HostNetworkPendingCommitService.claimPath(device)
        let keeping = HostNetworkPendingCommitService.keepingPath(device)
        let nm = nmConnection.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "#!/bin/sh",
            rollbackClaimShell(claim: claim, stamp: stamp, keeping: keeping),
        ]
        if !nm.isEmpty {
            for cidr in restoreCIDRs {
                lines.append(
                    "/usr/bin/nmcli connection modify \"\(nm)\" +ipv4.addresses \(cidr) >/dev/null 2>&1 || true",
                )
            }
            for cidr in cidrs {
                lines.append(
                    "/usr/bin/nmcli connection modify \"\(nm)\" -ipv4.addresses \(cidr) >/dev/null 2>&1 || true",
                )
            }
            lines.append("/usr/bin/nmcli connection reload >/dev/null 2>&1 || true")
        }
        if persistRestore.isEmpty {
            lines.append(contentsOf: persistFiles.map { "rm -rf \($0) || true" })
        } else {
            for (path, previous) in persistRestore {
                if let previous {
                    let dir = (path as NSString).deletingLastPathComponent
                    lines.append("mkdir -p \(dir) || true")
                    lines.append("cat > \(path) <<'BARKVISOR_PERSIST_RESTORE'")
                    lines.append(previous)
                    lines.append("BARKVISOR_PERSIST_RESTORE")
                } else {
                    lines.append("rm -rf \(path) || true")
                }
            }
        }
        lines.append(contentsOf: cidrs.map { cidr in
            "/sbin/ip addr del \(cidr) dev \(iface) >/dev/null 2>&1 || /usr/sbin/ip addr del \(cidr) dev \(iface) >/dev/null 2>&1 || true"
        })
        lines.append(contentsOf: restoreCIDRs.map { cidr in
            "/sbin/ip addr add \(cidr) dev \(iface) >/dev/null 2>&1 || /usr/sbin/ip addr add \(cidr) dev \(iface) >/dev/null 2>&1 || true"
        })
        lines.append("/usr/bin/networkctl reload >/dev/null 2>&1 || true")
        lines.append("rm -f \(pending) || true")
        lines.append("rmdir \(claim) 2>/dev/null || true")
        return lines.joined(separator: "\n") + "\n"
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

extension LinuxHostBridgeApply {
    fileprivate static func deletePlan(
        request: LinuxHostBridgeApplyRequest,
        probe: LinuxHostBridgeApplyProbe,
    ) -> LinuxHostBridgeApplyResult {
        if !probe.owned {
            return refuse(
                backend: probe.backend,
                message: "No BarkVisor marker for \(request.bridge). Will not delete a shared bridge.",
            )
        }
        if !probe.createdBridge {
            return refuse(
                backend: probe.backend,
                message: "Refuse delete of foreign \(request.bridge). Revert strips BarkVisor files only.",
            )
        }
        if request.attachedWorkloadCount > 0 {
            let n = request.attachedWorkloadCount
            return LinuxHostBridgeApplyResult(
                success: false,
                applied: false,
                backend: probe.backend.rawValue,
                message: "Cannot delete \(request.bridge): \(n) Workload\(n == 1 ? "" : "s") still reference it.",
                refused: true,
                conflict: true,
            )
        }
        if probe.backend == .ifupdown || probe.backend == .unknown {
            return refuse(
                backend: probe.backend,
                message: "Refuse \(probe.backend.rawValue). Cannot delete a manager we do not own.",
            )
        }
        let nic = resolvedNic(request: request, probe: probe)
        let members = probe.facts.bridges.first { $0.name == request.bridge }?.enslaved ?? []
        let ports = members.isEmpty && !nic.isEmpty ? [nic] : members
        var changes: [LinuxHostBridgeChange] = []
        let persist = systemdBridgePersist(bridge: request.bridge)
        for path in persist.remove {
            changes.append(LinuxHostBridgeChange(
                description: "Remove \(path) so \(request.bridge) is not recreated on boot",
                command: "sudo rm -f \(path)",
            ))
        }
        for path in persist.rewrite {
            changes.append(LinuxHostBridgeChange(
                description: "Stop enslaving the NIC in \(path)",
                command: "sudo sed -i '/^Bridge=\(request.bridge)$/d' \(path)",
            ))
        }
        if !persist.remove.isEmpty || !persist.rewrite.isEmpty {
            changes.append(LinuxHostBridgeChange(
                description: "Reload systemd-networkd",
                command: "sudo networkctl reload",
            ))
        }
        switch probe.backend {
        case .networkManager:
            for port in ports {
                changes.append(LinuxHostBridgeChange(
                    description: "Detach \(port) from \(request.bridge)",
                    command: "sudo ip link set \(port) nomaster",
                ))
            }
            if !nic.isEmpty {
                changes.append(LinuxHostBridgeChange(
                    description: "Move Device addresses from \(request.bridge) onto \(nic)",
                    command: "sudo bash -c 'ip -4 -o addr show dev \(request.bridge) | awk \"{print \\$4}\" | while read -r c; do ip addr add \"$c\" dev \(nic); done'",
                ))
            }
            for port in ports {
                changes.append(LinuxHostBridgeChange(
                    description: "Delete NetworkManager slave \(nmSlaveConnectionName(bridge: request.bridge, nic: port))",
                    command: "sudo nmcli connection delete \(nmSlaveConnectionName(bridge: request.bridge, nic: port))",
                ))
            }
            changes.append(LinuxHostBridgeChange(
                description: "Delete NetworkManager connection barkvisor-\(request.bridge)",
                command: "sudo nmcli connection delete barkvisor-\(request.bridge)",
            ))
            if request.bridge != "barkvisor-\(request.bridge)" {
                changes.append(LinuxHostBridgeChange(
                    description: "Delete NetworkManager connection \(request.bridge)",
                    command: "sudo nmcli connection delete \(request.bridge)",
                ))
            }
            changes.append(LinuxHostBridgeChange(
                description: "Delete \(request.bridge)",
                command: "sudo ip link delete \(request.bridge) type bridge",
            ))
            if !nic.isEmpty {
                changes.append(LinuxHostBridgeChange(
                    description: "Keep DHCP plus moved addresses on \(nic)",
                    command: "sudo nmcli connection modify \(nic) ipv4.method auto",
                ))
                changes.append(LinuxHostBridgeChange(
                    description: "Restore L3 on \(nic)",
                    command: "sudo nmcli connection up \(nic)",
                ))
                changes.append(LinuxHostBridgeChange(
                    description: "Reapply \(nic)",
                    command: "sudo nmcli device reapply \(nic)",
                ))
            }
        case .netplan:
            changes.append(LinuxHostBridgeChange(
                description: "Remove \(netplanPath(bridge: request.bridge))",
                command: "sudo rm -f \(netplanPath(bridge: request.bridge))",
            ))
            for port in ports {
                changes.append(LinuxHostBridgeChange(
                    description: "Detach \(port) from \(request.bridge)",
                    command: "sudo ip link set \(port) nomaster",
                ))
            }
            changes.append(LinuxHostBridgeChange(
                description: "Delete \(request.bridge)",
                command: "sudo ip link delete \(request.bridge) type bridge",
            ))
            changes.append(LinuxHostBridgeChange(
                description: "Restore L3 with netplan",
                command: "sudo netplan try --timeout \(rollbackSeconds)",
            ))
        case .systemdNetworkd:
            var units = "\(networkdNetdevPath(bridge: request.bridge)) \(networkdNetworkPath(bridge: request.bridge))"
            if !nic.isEmpty {
                units += " \(networkdPortPath(nic: nic))"
            }
            changes.append(LinuxHostBridgeChange(
                description: "Remove systemd-networkd barkvisor units",
                command: "sudo rm -f \(units) && sudo networkctl reload",
            ))
            for port in ports {
                changes.append(LinuxHostBridgeChange(
                    description: "Detach \(port) from \(request.bridge)",
                    command: "sudo ip link set \(port) nomaster",
                ))
            }
            changes.append(LinuxHostBridgeChange(
                description: "Delete \(request.bridge)",
                command: "sudo ip link delete \(request.bridge) type bridge",
            ))
            if !nic.isEmpty {
                changes.append(LinuxHostBridgeChange(
                    description: "Restore L3 on \(nic)",
                    command: "sudo networkctl reapply \(nic)",
                ))
            }
        case .ifupdown, .unknown:
            break
        }
        changes.append(LinuxHostBridgeChange(
            description: "Remove marker-tagged allow \(request.bridge) from \(HostBridgeFactsService.defaultACLPath)",
            command: "# strip \(aclMarker(for: request.bridge)) + allow \(request.bridge)",
        ))
        changes.append(LinuxHostBridgeChange(
            description: "Delete Workload networks that use \(request.bridge)",
            command: "DELETE /api/networks (bridge=\(request.bridge))",
        ))
        if !request.confirm {
            return LinuxHostBridgeApplyResult(
                success: true,
                applied: false,
                needsConfirm: true,
                backend: probe.backend.rawValue,
                changes: changes.map(\.description),
                warnings: probe.sessionWarnings,
                commands: changes.map(\.command),
                message: "Confirm required before delete.",
            )
        }
        return LinuxHostBridgeApplyResult(
            success: true,
            applied: false,
            needsConfirm: false,
            backend: probe.backend.rawValue,
            changes: changes.map(\.description),
            warnings: probe.sessionWarnings,
            commands: changes.map(\.command),
            message: "Ready to delete owned \(request.bridge).",
        )
    }

    public static func createdBridgeForUplink(_ uplink: String, dataDir: URL = Config.dataDir) -> Bool {
        if readOwnerMarker(bridge: uplink, dataDir: dataDir)?.createdBridge == true {
            return true
        }
        for name in listedMarkerBridges(dataDir: dataDir) {
            if let marker = readOwnerMarker(bridge: name, dataDir: dataDir),
               marker.uplink == uplink {
                return marker.createdBridge
            }
        }
        return false
    }

    fileprivate static func bridgeNameExists(_ bridge: String, probe: LinuxHostBridgeApplyProbe) -> Bool {
        probe.existingInterfaces.contains(bridge) || probe.facts.bridges.contains { $0.name == bridge }
    }

    fileprivate static func validInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count < 16, !name.contains("/"), !name.contains("\0") else {
            return false
        }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
    }

    fileprivate static func existingInterfaceNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: LinuxHostNetwork.netClassPath)) ?? []
    }

    fileprivate static func sessionRisk(facts: HostBridgeFacts, listenPort: Int) -> (
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

    fileprivate static func establishedOnPort(_ port: Int) -> Bool {
        tcpTableHasPort(path: "/proc/net/tcp", port: port, established: true)
            || tcpTableHasPort(path: "/proc/net/tcp6", port: port, established: true)
    }

    fileprivate static func listeningOnPort(_ port: Int) -> Bool {
        tcpTableHasPort(path: "/proc/net/tcp", port: port, established: false)
            || tcpTableHasPort(path: "/proc/net/tcp6", port: port, established: false)
    }

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
}
