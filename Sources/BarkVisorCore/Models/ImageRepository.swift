import Foundation
import GRDB

public struct ImageRepository: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "image_repositories"

    public var id: String
    public var name: String
    public var url: String
    public var isBuiltIn: Bool
    public var repoType: String // "images", "templates", "both"
    public var lastSyncedAt: String?
    public var lastError: String?
    public var syncStatus: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        url: String,
        isBuiltIn: Bool,
        repoType: String,
        lastSyncedAt: String?,
        lastError: String?,
        syncStatus: String,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isBuiltIn = isBuiltIn
        self.repoType = repoType
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.syncStatus = syncStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
