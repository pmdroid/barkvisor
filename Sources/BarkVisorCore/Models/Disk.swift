import Foundation
import GRDB

public struct Disk: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "disks"

    public var id: String
    public var name: String
    public var path: String
    public var sizeBytes: Int64
    public var format: String
    public var vmId: String?
    public var autoCreated: Bool
    public var status: String
    public var createdAt: String

    public init(
        id: String,
        name: String,
        path: String,
        sizeBytes: Int64,
        format: String,
        vmId: String?,
        autoCreated: Bool,
        status: String,
        createdAt: String,
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.format = format
        self.vmId = vmId
        self.autoCreated = autoCreated
        self.status = status
        self.createdAt = createdAt
    }
}
