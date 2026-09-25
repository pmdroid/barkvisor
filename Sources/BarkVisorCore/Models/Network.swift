import Foundation
import GRDB

public struct Network: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "networks"

    public var id: String
    public var name: String
    public var mode: String
    public var bridge: String?
    public var macAddress: String?
    public var dnsServer: String?
    public var autoCreated: Bool
    public var isDefault: Bool

    public init(
        id: String,
        name: String,
        mode: String,
        bridge: String?,
        macAddress: String?,
        dnsServer: String?,
        autoCreated: Bool,
        isDefault: Bool,
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.bridge = bridge
        self.macAddress = macAddress
        self.dnsServer = dnsServer
        self.autoCreated = autoCreated
        self.isDefault = isDefault
    }
}

public struct PortForwardRule: Codable, Equatable, Sendable {
    public let `protocol`: String
    public let hostPort: Int
    public let guestPort: Int
    public let httpPath: String?
    public let host: String?

    public init(
        protocol: String,
        hostPort: Int,
        guestPort: Int,
        httpPath: String? = nil,
        host: String? = nil,
    ) {
        self.protocol = `protocol`
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.httpPath = httpPath
        self.host = host
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case hostPort
        case guestPort
        case httpPath
        case host
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocol = try container.decode(String.self, forKey: .protocol)
        hostPort = try container.decode(Int.self, forKey: .hostPort)
        guestPort = try container.decode(Int.self, forKey: .guestPort)
        httpPath = try container.decodeIfPresent(String.self, forKey: .httpPath)
        host = try container.decodeIfPresent(String.self, forKey: .host)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(hostPort, forKey: .hostPort)
        try container.encode(guestPort, forKey: .guestPort)
        try container.encodeIfPresent(httpPath, forKey: .httpPath)
        try container.encodeIfPresent(host, forKey: .host)
    }
}
