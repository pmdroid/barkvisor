import Foundation

/// Copyable host-bridge setup step for Manage Bridges (PAS-222 / PAS-236).
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

    public init(
        helperPath: String? = nil,
        helperSetuid: Bool = false,
        aclAllowsSuggested: Bool? = nil,
        bridges: [HostBridgeSnapshot] = [],
        defaultRouteInterface: String? = nil,
    ) {
        self.helperPath = helperPath
        self.helperSetuid = helperSetuid
        self.aclAllowsSuggested = aclAllowsSuggested
        self.bridges = bridges
        self.defaultRouteInterface = defaultRouteInterface
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
            let bridges = LinuxHostNetwork.listBridgeInterfaces().map { name in
                HostBridgeSnapshot(
                    name: name,
                    enslaved: LinuxHostNetwork.enslavedInterfaces(onBridge: name),
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
            return .empty
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

    public static func assemble(from inputs: HostBridgeFactInputs) -> HostBridgeFacts {
        let enslaved = Set(inputs.bridges.flatMap(\.enslaved))
        let hasBridge = !inputs.bridges.isEmpty
        let onlyUplink: Bool = if let def = inputs.defaultRouteInterface, !def.isEmpty {
            !enslaved.contains(def) && !hasBridge
        } else {
            false
        }
        let ready = hasBridge && inputs.helperSetuid && inputs.aclAllowsSuggested == true
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
        let br = suggestedBridgeName
        let helper = inputs.helperPath ?? qemuBridgeHelperCandidates[0]
        var groups: [HostBridgeRemediation] = []
        if inputs.bridges.isEmpty {
            groups.append(HostBridgeRemediation(
                id: "create-bridge",
                label: "Create \(br)",
                commands: [
                    "sudo ip link add name \(br) type bridge",
                    "sudo ip link set \(br) up",
                    "# Then put the host IP/DHCP on \(br), not the physical NIC.",
                    "# sudo ip link set <nic> master \(br)",
                ].joined(separator: "\n"),
            ))
        }
        if inputs.aclAllowsSuggested != true {
            groups.append(HostBridgeRemediation(
                id: "allow-acl",
                label: "Allow \(br) in qemu-bridge.conf",
                commands: "echo 'allow \(br)' | sudo tee \(defaultACLPath)",
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
    public static func statusByInterface(records: [BridgeRecord]) -> [String: String] {
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            return Dictionary(uniqueKeysWithValues: records.map { ($0.interface, $0.status) })
        }
        return Dictionary(uniqueKeysWithValues: probe().bridges.map { ($0.name, "active") })
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
}
