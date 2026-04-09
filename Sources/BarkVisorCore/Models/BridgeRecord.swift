import Foundation
import GRDB

public struct BridgeRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "bridges"

    public var id: Int64?
    public var interface: String
    public var socketPath: String?
    public var plistExists: Bool
    public var daemonRunning: Bool
    public var status: String
    public var updatedAt: String

    public init(
        id: Int64?,
        interface: String,
        socketPath: String?,
        plistExists: Bool,
        daemonRunning: Bool,
        status: String,
        updatedAt: String,
    ) {
        self.id = id
        self.interface = interface
        self.socketPath = socketPath
        self.plistExists = plistExists
        self.daemonRunning = daemonRunning
        self.status = status
        self.updatedAt = updatedAt
    }
}
