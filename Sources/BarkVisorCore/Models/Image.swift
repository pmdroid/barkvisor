import Foundation
import GRDB

public struct VMImage: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "images"

    public var id: String
    public var name: String
    public var imageType: String
    public var arch: String
    public var path: String?
    public var sizeBytes: Int64?
    public var status: String
    public var error: String?
    public var sourceUrl: String?
    public var createdAt: String
    public var updatedAt: String

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let status = Column(CodingKeys.status)
    }

    public init(
        id: String,
        name: String,
        imageType: String,
        arch: String,
        path: String?,
        sizeBytes: Int64?,
        status: String,
        error: String?,
        sourceUrl: String?,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.name = name
        self.imageType = imageType
        self.arch = arch
        self.path = path
        self.sizeBytes = sizeBytes
        self.status = status
        self.error = error
        self.sourceUrl = sourceUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
