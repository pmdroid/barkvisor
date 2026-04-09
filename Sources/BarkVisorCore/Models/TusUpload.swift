import Foundation
import GRDB

public struct TusUpload: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "tus_uploads"

    public var id: String
    public var imageId: String
    public var offset: Int64
    public var length: Int64
    public var metadata: String
    public var chunkPath: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        imageId: String,
        offset: Int64,
        length: Int64,
        metadata: String,
        chunkPath: String,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.imageId = imageId
        self.offset = offset
        self.length = length
        self.metadata = metadata
        self.chunkPath = chunkPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
