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

public struct PortForwardRule: Codable, Sendable {
    public let `protocol`: String
    public let hostPort: Int
    public let guestPort: Int
    public let httpPath: String?

    public init(protocol: String, hostPort: Int, guestPort: Int, httpPath: String? = nil) {
        self.protocol = `protocol`
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.httpPath = httpPath
    }
}
