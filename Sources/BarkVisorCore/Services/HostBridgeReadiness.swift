import Foundation

/// Live Linux host-bridge probe for Manage Bridges (PAS-222).
/// Detection only — never mutates the host.
public struct HostBridgeSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var enslaved: [String]

    public init(name: String, enslaved: [String]) {
        self.name = name
        self.enslaved = enslaved
    }
}

public struct HostBridgeReadiness: Codable, Sendable, Equatable {
    public var helperPath: String?
    public var helperSetuid: Bool
    public var suggestedBridge: String
    public var aclAllowsSuggested: Bool?
    public var bridges: [HostBridgeSnapshot]
    public var defaultRouteInterface: String?
    public var onlyUplink: Bool
    public var ready: Bool

    public init(
        helperPath: String?,
        helperSetuid: Bool,
        suggestedBridge: String,
        aclAllowsSuggested: Bool?,
        bridges: [HostBridgeSnapshot],
        defaultRouteInterface: String?,
        onlyUplink: Bool,
        ready: Bool,
    ) {
        self.helperPath = helperPath
        self.helperSetuid = helperSetuid
        self.suggestedBridge = suggestedBridge
        self.aclAllowsSuggested = aclAllowsSuggested
        self.bridges = bridges
        self.defaultRouteInterface = defaultRouteInterface
        self.onlyUplink = onlyUplink
        self.ready = ready
    }
}

public enum HostBridgeReadinessService {
    public static let suggestedBridgeName = "br0"

    public static func probe() -> HostBridgeReadiness {
        #if os(Linux)
            return probeLinux()
        #else
            return HostBridgeReadiness(
                helperPath: nil,
                helperSetuid: false,
                suggestedBridge: suggestedBridgeName,
                aclAllowsSuggested: nil,
                bridges: [],
                defaultRouteInterface: nil,
                onlyUplink: false,
                ready: false,
            )
        #endif
    }

    #if os(Linux)
        private static func probeLinux() -> HostBridgeReadiness {
            let helper = LinuxHostNetwork.resolvedQemuBridgeHelperPath()
            let setuid = helper.map { LinuxHostNetwork.isSetuidExecutable(at: $0) } ?? false
            let bridges = LinuxHostNetwork.listBridgeInterfaces().map { name in
                HostBridgeSnapshot(
                    name: name,
                    enslaved: LinuxHostNetwork.enslavedInterfaces(onBridge: name),
                )
            }
            let def = LinuxHostNetwork.defaultRouteInterface()
            let enslaved = Set(bridges.flatMap(\.enslaved))
            let onlyUplink: Bool
            if let def, !def.isEmpty {
                onlyUplink = !enslaved.contains(def)
            } else {
                onlyUplink = false
            }
            let acl = LinuxHostNetwork.bridgeACLDecision(suggestedBridgeName)
            let hasBridge = !bridges.isEmpty
            let ready = hasBridge && setuid && acl == true
            return HostBridgeReadiness(
                helperPath: helper,
                helperSetuid: setuid,
                suggestedBridge: suggestedBridgeName,
                aclAllowsSuggested: acl,
                bridges: bridges,
                defaultRouteInterface: def,
                onlyUplink: onlyUplink && !hasBridge,
                ready: ready,
            )
        }
    #endif
}
