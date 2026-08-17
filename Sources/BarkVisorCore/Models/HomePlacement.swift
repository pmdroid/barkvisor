import Foundation

/// `POST /api/home/placement/score` body (PAS-44 + PAS-43).
///
/// Reuses Wave 0 template fields. USB/GPU peripheral matching is PAS-91.
public struct HomePlacementScoreRequest: Codable, Sendable, Equatable {
    public var declaredArchitectures: [String]
    public var requiredFeatures: [String]
    public var minMemoryMB: Int?
    public var requestedMemoryMB: Int?

    public init(
        declaredArchitectures: [String] = [],
        requiredFeatures: [String] = [],
        minMemoryMB: Int? = nil,
        requestedMemoryMB: Int? = nil,
    ) {
        self.declaredArchitectures = declaredArchitectures
        self.requiredFeatures = requiredFeatures
        self.minMemoryMB = minMemoryMB
        self.requestedMemoryMB = requestedMemoryMB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        declaredArchitectures = try container.decodeIfPresent([String].self, forKey: .declaredArchitectures) ?? []
        requiredFeatures = try container.decodeIfPresent([String].self, forKey: .requiredFeatures) ?? []
        minMemoryMB = try container.decodeIfPresent(Int.self, forKey: .minMemoryMB)
        requestedMemoryMB = try container.decodeIfPresent(Int.self, forKey: .requestedMemoryMB)
    }
}

public struct HomePlacementReason: Codable, Sendable, Equatable {
    public var code: String
    public var kind: String
    public var message: String

    public init(code: String, kind: String, message: String) {
        self.code = code
        self.kind = kind
        self.message = message
    }

    public static func hard(_ code: String, _ message: String) -> HomePlacementReason {
        HomePlacementReason(code: code, kind: HomePlacementScorer.hardKind, message: message)
    }

    public static func soft(_ code: String, _ message: String) -> HomePlacementReason {
        HomePlacementReason(code: code, kind: HomePlacementScorer.softKind, message: message)
    }
}

public struct HomePlacementCandidate: Codable, Sendable, Equatable {
    public var hostId: String
    public var displayName: String?
    public var role: String
    public var eligible: Bool
    public var recommended: Bool
    public var rank: Int
    public var score: Int
    public var reasons: [HomePlacementReason]

    public init(
        hostId: String,
        displayName: String?,
        role: String,
        eligible: Bool,
        recommended: Bool,
        rank: Int,
        score: Int,
        reasons: [HomePlacementReason],
    ) {
        self.hostId = hostId
        self.displayName = displayName
        self.role = role
        self.eligible = eligible
        self.recommended = recommended
        self.rank = rank
        self.score = score
        self.reasons = reasons
    }
}

/// Ranked Devices. Never places a workload — the SPA must confirm or override.
public struct HomePlacementScoreResponse: Codable, Sendable, Equatable {
    public var recommendedHostId: String?
    public var candidates: [HomePlacementCandidate]

    enum CodingKeys: String, CodingKey {
        case recommendedHostId
        case candidates
    }

    public init(recommendedHostId: String?, candidates: [HomePlacementCandidate]) {
        self.recommendedHostId = recommendedHostId
        self.candidates = candidates
    }

    /// Always emit `recommendedHostId` so the OpenAPI required+nullable contract
    /// is met when no Device is eligible (JSON null, not an omitted key).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let recommendedHostId {
            try container.encode(recommendedHostId, forKey: .recommendedHostId)
        } else {
            try container.encodeNil(forKey: .recommendedHostId)
        }
        try container.encode(candidates, forKey: .candidates)
    }
}
