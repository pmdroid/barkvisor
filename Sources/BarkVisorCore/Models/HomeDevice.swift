import Foundation

/// One Device in this Home (PAS-34).
///
/// `self` is always this process. `member` rows come from the local
/// pairing registry — listing never contacts peers (PAS-47 / PAS-90).
public struct HomeDevice: Codable, Sendable, Equatable {
    public var hostId: String
    public var role: String
    public var fingerprint: String?
    public var displayName: String?
    public var agentHost: String?
    public var agentPort: Int
    public var pairedAt: String?

    public init(
        hostId: String,
        role: String,
        fingerprint: String? = nil,
        displayName: String? = nil,
        agentHost: String? = nil,
        agentPort: Int = Config.agentPort,
        pairedAt: String? = nil,
    ) {
        self.hostId = hostId
        self.role = role
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.pairedAt = pairedAt
    }
}

/// `GET /api/home/devices` body.
public struct HomeDeviceList: Codable, Sendable, Equatable {
    public var devices: [HomeDevice]

    public init(devices: [HomeDevice]) {
        self.devices = devices
    }
}

/// Persisted member row at `dataDir/agent/devices.json`.
public struct DeviceRecord: Codable, Sendable, Equatable {
    public var hostId: String
    public var fingerprint: String
    public var agentHost: String?
    public var agentPort: Int
    public var pairedAt: String

    public init(
        hostId: String,
        fingerprint: String,
        agentHost: String? = nil,
        agentPort: Int = Config.agentPort,
        pairedAt: String,
    ) {
        self.hostId = hostId
        self.fingerprint = fingerprint.lowercased()
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.pairedAt = pairedAt
    }

    enum CodingKeys: String, CodingKey {
        case hostId, fingerprint, agentHost, agentPort, pairedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostId = try container.decode(String.self, forKey: .hostId)
        self.fingerprint = try container.decode(String.self, forKey: .fingerprint).lowercased()
        self.agentHost = try container.decodeIfPresent(String.self, forKey: .agentHost)
        self.agentPort = try container.decodeIfPresent(Int.self, forKey: .agentPort) ?? Config.agentPort
        self.pairedAt = try container.decode(String.self, forKey: .pairedAt)
    }
}
