import Foundation

/// Live host-bridge snapshot for Manage Bridges (PAS-222 wire).
/// Detection only — never mutates the host. Assembled by `HostBridgeFactsService`.
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
    public var remediations: [HostBridgeRemediation]?

    public init(
        helperPath: String?,
        helperSetuid: Bool,
        suggestedBridge: String,
        aclAllowsSuggested: Bool?,
        bridges: [HostBridgeSnapshot],
        defaultRouteInterface: String?,
        onlyUplink: Bool,
        ready: Bool,
        remediations: [HostBridgeRemediation]? = nil,
    ) {
        self.helperPath = helperPath
        self.helperSetuid = helperSetuid
        self.suggestedBridge = suggestedBridge
        self.aclAllowsSuggested = aclAllowsSuggested
        self.bridges = bridges
        self.defaultRouteInterface = defaultRouteInterface
        self.onlyUplink = onlyUplink
        self.ready = ready
        self.remediations = remediations
    }
}

public enum HostBridgeReadinessService {
    public static let suggestedBridgeName = HostBridgeFactsService.suggestedBridgeName

    /// Host-facts seam: pass `source` in tests. Live probe uses `LiveHostBridgeFactSource`.
    public static func probe(source: any HostBridgeFactSource = LiveHostBridgeFactSource())
        -> HostBridgeReadiness {
        HostBridgeFactsService.readiness(source: source)
    }
}
