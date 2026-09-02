import Foundation

/// Copyable host-bridge setup step for Bridge setup (PAS-222 / PAS-236).
public struct HostBridgeRemediation: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var commands: String

    public init(id: String, label: String, commands: String) {
        self.id = id
        self.label = label
        self.commands = commands
    }
}

/// Probe inputs. Linux sysfs / macOS PrivilegeService fill this; tests inject it.
public struct HostBridgeFactInputs: Sendable, Equatable {
    public var helperPath: String?
    public var helperSetuid: Bool
    public var aclAllowsSuggested: Bool?
    public var bridges: [HostBridgeSnapshot]
    public var defaultRouteInterface: String?
    /// Homebrew `socket_vmnet` (no qemu-bridge-helper / ACL).
    public var macSocketVmnet: Bool

    public init(
        helperPath: String? = nil,
        helperSetuid: Bool = false,
        aclAllowsSuggested: Bool? = nil,
        bridges: [HostBridgeSnapshot] = [],
        defaultRouteInterface: String? = nil,
        macSocketVmnet: Bool = false,
    ) {
        self.helperPath = helperPath
        self.helperSetuid = helperSetuid
        self.aclAllowsSuggested = aclAllowsSuggested
        self.bridges = bridges
        self.defaultRouteInterface = defaultRouteInterface
        self.macSocketVmnet = macSocketVmnet
    }

    public static let empty = HostBridgeFactInputs()
}

public protocol HostBridgeFactSource: Sendable {
    func inputs() -> HostBridgeFactInputs
}

/// Linux sysfs adapter. macOS has no qemu-bridge-helper host-bridge facts
/// (managed daemons stay on PrivilegeService).
public struct LiveHostBridgeFactSource: HostBridgeFactSource {
    public init() {}

    public func inputs() -> HostBridgeFactInputs {
        #if os(Linux)
            let helper = LinuxHostNetwork.resolvedQemuBridgeHelperPath()
            let setuid = helper.map { LinuxHostNetwork.isSetuidExecutable(at: $0) } ?? false
            let acl = try? String(
                contentsOfFile: HostBridgeFactsService.defaultACLPath,
                encoding: .utf8,
            )
            let bridges = LinuxHostNetwork.listBridgeInterfaces().map { name -> HostBridgeSnapshot in
                let marker = LinuxHostBridgeApply.readOwnerMarker(bridge: name)
                return HostBridgeSnapshot(
                    name: name,
                    enslaved: LinuxHostNetwork.enslavedInterfaces(onBridge: name),
                    createdBridge: LinuxHostBridgeApply.ownership(
                        bridge: name,
                        marker: marker,
                        acl: acl,
                        leftoverPersist: LinuxHostBridgeApply.leftoverHostBridge(bridge: name),
                    ).createdBridge,
                )
            }
            return HostBridgeFactInputs(
                helperPath: helper,
                helperSetuid: setuid,
                aclAllowsSuggested: LinuxHostNetwork.bridgeACLDecision(
                    HostBridgeFactsService.suggestedBridgeName,
                ),
                bridges: bridges,
                defaultRouteInterface: LinuxHostNetwork.defaultRouteInterface(),
            )
        #else
            let sockets = SocketVmnetDiscovery.existingSockets()
            return HostBridgeFactInputs(
                bridges: HostBridgeFactsService.macSyntheticBridges(
                    markers: LinuxHostBridgeApply.listOwnerMarkers(),
                    sockets: sockets,
                ),
                defaultRouteInterface: SocketVmnetDiscovery.sharedUplinkInterface(),
                macSocketVmnet: true,
            )
        #endif
    }
}

/// Assembled host-bridge facts for the SPA (PAS-236).
public struct HostBridgeFacts: Sendable, Equatable {
    public var helperPath: String?
    public var helperSetuid: Bool
    public var suggestedBridge: String
    public var aclPath: String
    public var aclAllowsSuggested: Bool?
    public var bridges: [HostBridgeSnapshot]
    public var defaultRouteInterface: String?
    public var onlyUplink: Bool
    public var ready: Bool
    public var remediations: [HostBridgeRemediation]

    public var readiness: HostBridgeReadiness {
        HostBridgeReadiness(
            helperPath: helperPath,
            helperSetuid: helperSetuid,
            suggestedBridge: suggestedBridge,
            aclAllowsSuggested: aclAllowsSuggested,
            bridges: bridges,
            defaultRouteInterface: defaultRouteInterface,
            onlyUplink: onlyUplink,
            ready: ready,
            remediations: remediations,
            pendingCommit: HostNetworkPendingCommitService.activePending()?.publicInfo,
        )
    }
}

/// One owner of host-bridge discovery, readiness, and remediation facts.
/// Linux sysfs (`LinuxHostNetwork`) and macOS `PrivilegeService` are adapters.
public enum HostBridgeFactsService {
    public static let suggestedBridgeName = "br0"
    public static let defaultACLPath = "/etc/qemu/bridge.conf"
    public static let qemuBridgeHelperCandidates = [
        "/usr/lib/qemu/qemu-bridge-helper",
        "/usr/libexec/qemu-bridge-helper",
        "/usr/local/libexec/qemu/qemu-bridge-helper",
    ]

    /// Live host probe. Pass `source` in tests — do not hit sysfs from unit tests.
    public static func probe(source: any HostBridgeFactSource = LiveHostBridgeFactSource())
        -> HostBridgeFacts {
        assemble(from: source.inputs())
    }

    public static func readiness(source: any HostBridgeFactSource = LiveHostBridgeFactSource())
        -> HostBridgeReadiness {
        probe(source: source).readiness
    }

    /// Same constants as a live Linux miss: not ready, copyable setup steps.
    public static func fallbackReadiness() -> HostBridgeReadiness {
        assemble(from: HostBridgeFactInputs(
            helperPath: qemuBridgeHelperCandidates[0],
            helperSetuid: false,
            aclAllowsSuggested: false,
            bridges: [],
            defaultRouteInterface: nil,
        )).readiness
    }

    public static func syntheticMacBridgeName(uplink: String) -> String {
        let port = uplink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !port.isEmpty else { return "" }
        return "\(port)-bridge"
    }

    public static func macSyntheticBridges(
        markers: [LinuxHostBridgeApply.OwnerMarker],
        sockets: [(interface: String, path: String)] = [],
    ) -> [HostBridgeSnapshot] {
        let fromMarkers = markers.compactMap { marker -> HostBridgeSnapshot? in
            guard let uplink = marker.uplink, !uplink.isEmpty else { return nil }
            let name = marker.bridge.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return HostBridgeSnapshot(
                name: name,
                enslaved: [uplink],
                createdBridge: true,
            )
        }
        if !fromMarkers.isEmpty {
            return fromMarkers
        }
        return sockets.compactMap { item -> HostBridgeSnapshot? in
            if SocketVmnetDiscovery.isSharedSocketPath(item.path) { return nil }
            let name = syntheticMacBridgeName(uplink: item.interface)
            guard !name.isEmpty else { return nil }
            return HostBridgeSnapshot(name: name, enslaved: [item.interface], createdBridge: true)
        }
    }

    public static func assemble(from inputs: HostBridgeFactInputs) -> HostBridgeFacts {
        let enslaved = Set(inputs.bridges.flatMap(\.enslaved))
        let hasBridge = !inputs.bridges.isEmpty
        let onlyUplink: Bool = if let def = inputs.defaultRouteInterface, !def.isEmpty {
            !enslaved.contains(def) && !hasBridge
        } else {
            false
        }
        let ready = if inputs.macSocketVmnet {
            hasBridge
        } else {
            hasBridge && inputs.helperSetuid && inputs.aclAllowsSuggested == true
        }
        return HostBridgeFacts(
            helperPath: inputs.helperPath,
            helperSetuid: inputs.helperSetuid,
            suggestedBridge: suggestedBridgeName,
            aclPath: defaultACLPath,
            aclAllowsSuggested: inputs.aclAllowsSuggested,
            bridges: inputs.bridges,
            defaultRouteInterface: inputs.defaultRouteInterface,
            onlyUplink: onlyUplink,
            ready: ready,
            remediations: remediations(from: inputs),
        )
    }

    public static func remediations(from inputs: HostBridgeFactInputs) -> [HostBridgeRemediation] {
        if inputs.macSocketVmnet {
            if inputs.bridges.isEmpty {
                return [
                    HostBridgeRemediation(
                        id: "homebrew-socket-vmnet",
                        label: "Install and start socket_vmnet",
                        commands: SocketVmnetDiscovery.installHint.replacingOccurrences(
                            of: " && ",
                            with: "\n",
                        ),
                    ),
                ]
            }
            return []
        }
        let br = suggestedBridgeName
        let helper = inputs.helperPath ?? qemuBridgeHelperCandidates[0]
        var groups: [HostBridgeRemediation] = []
        if inputs.bridges.isEmpty {
            groups.append(HostBridgeRemediation(
                id: "create-bridge",
                label: "Create \(br)",
                commands: [
                    "Networks → Host interfaces → Create → Bridge.",
                    "# After Apply: Keep changes within 30s in the SPA (POST action commit) or the host auto-reverts.",
                    "curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \\",
                    "  -H 'Content-Type: application/json' \\",
                    "  -d '{\"interface\":\"<wired-uplink>\",\"bridge\":\"\(br)\",\"action\":\"apply\",\"confirm\":true,\"addressing\":\"dhcp\"}'",
                ].joined(separator: "\n"),
            ))
        }
        if inputs.aclAllowsSuggested != true {
            let marker = LinuxHostBridgeApply.aclMarker(for: br)
            groups.append(HostBridgeRemediation(
                id: "allow-acl",
                label: "Allow \(br) in qemu-bridge.conf",
                commands: [
                    "# \(marker)",
                    "printf '%s\\n%s\\n' '\(marker)' 'allow \(br)' | sudo tee -a \(defaultACLPath)",
                ].joined(separator: "\n"),
            ))
        }
        if !inputs.helperSetuid {
            groups.append(HostBridgeRemediation(
                id: "setuid-helper",
                label: "Setuid qemu-bridge-helper",
                commands: "sudo chmod u+s \(helper)",
            ))
        }
        return groups
    }

    /// Linux host bridges as API rows. Never sets `plistExists` / `daemonRunning`.
    public static func hostBridgeInfos(from facts: HostBridgeFacts) -> [BridgeStateDTO] {
        facts.bridges.map { snap in
            BridgeStateDTO(
                interface: snap.name,
                socketPath: nil,
                plistExists: false,
                daemonRunning: false,
                status: "active",
            )
        }
    }

    /// Interface → status for setup / system UI.
    /// macOS: managed-daemon DB rows. Linux: live facts (not fabricated plist rows).
    public static func statusByInterface(
        records: [BridgeRecord],
        source: any HostBridgeFactSource = LiveHostBridgeFactSource(),
    ) -> [String: String] {
        if PlatformCapabilities.supportsManagedBridgeDaemon, !records.isEmpty {
            return Dictionary(
                records.map { ($0.interface, $0.status) },
                uniquingKeysWith: { _, last in last },
            )
        }
        return Dictionary(
            probe(source: source).bridges.map { ($0.name, "active") },
            uniquingKeysWith: { _, last in last },
        )
    }

    /// One bridged `Network` row per host interface.
    public static func requireUnusedBridgedInterface(
        _ bridge: String,
        occupiedBy existing: Network?,
    ) throws {
        guard let existing else { return }
        throw BarkVisorError.conflict(
            "Interface '\(bridge)' is already used by network \"\(existing.name)\". Each interface can only have one bridge.",
        )
    }

    /// Interface for a bridged template that did not pass `networkId`.
    /// macOS: first active managed-daemon `BridgeRecord`. Linux: live facts, never `BridgeRecord`.
    public static func activeBridgedInterface(
        records: [BridgeRecord],
        source: any HostBridgeFactSource = LiveHostBridgeFactSource(),
    ) throws -> String {
        if PlatformCapabilities.supportsManagedBridgeDaemon, !records.isEmpty {
            guard let name = records.first(where: { $0.status == "active" })?.interface else {
                throw BarkVisorError.preconditionFailed(
                    """
                    This template requires bridged networking, but no socket_vmnet socket is active. \
                    \(SocketVmnetDiscovery.installHint).
                    """,
                )
            }
            return name
        }
        let facts = probe(source: source)
        let preferred = facts.bridges.first(where: { $0.name == suggestedBridgeName })
            ?? facts.bridges.first
        guard let name = preferred?.name else {
            #if os(macOS)
                throw BarkVisorError.preconditionFailed(
                    """
                    This template requires bridged networking, but socket_vmnet is not running. \
                    \(SocketVmnetDiscovery.installHint).
                    """,
                )
            #else
                throw BarkVisorError.preconditionFailed(
                    """
                    This template requires bridged networking, but no host bridge is present. \
                    Create a Linux bridge (for example \(suggestedBridgeName)) in Bridge setup, then retry.
                    """,
                )
            #endif
        }
        return name
    }
}
