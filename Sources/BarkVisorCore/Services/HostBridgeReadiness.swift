import Foundation

/// Live host-bridge snapshot for Bridge setup (PAS-222 wire).
/// Detection only — never mutates the host. Assembled by `HostBridgeFactsService`.
public struct HostBridgeSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var enslaved: [String]
    public var createdBridge: Bool

    enum CodingKeys: String, CodingKey {
        case name, enslaved, createdBridge
    }

    public init(name: String, enslaved: [String], createdBridge: Bool = false) {
        self.name = name
        self.enslaved = enslaved
        self.createdBridge = createdBridge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enslaved = try c.decodeIfPresent([String].self, forKey: .enslaved) ?? []
        createdBridge = try c.decodeIfPresent(Bool.self, forKey: .createdBridge) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(enslaved, forKey: .enslaved)
        try c.encode(createdBridge, forKey: .createdBridge)
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
    /// Post-apply keep window; null when no pending host network commit.
    public var pendingCommit: HostNetworkPendingCommitInfo?

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
        pendingCommit: HostNetworkPendingCommitInfo? = nil,
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
        self.pendingCommit = pendingCommit
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
