import Foundation

/// Identity of an mTLS peer on the agent plane (PAS-76).
///
/// Served only on the 7778 listener. SPA/JWT on 7777 is unchanged.
public struct AgentPeerIdentity: Codable, Sendable, Equatable {
    public var hostId: String
    public var fingerprint: String
    public var trust: String
    public var listener: String

    public init(
        hostId: String,
        fingerprint: String,
        trust: String,
        listener: String = "mtls",
    ) {
        self.hostId = hostId
        self.fingerprint = fingerprint
        self.trust = trust
        self.listener = listener
    }
}
