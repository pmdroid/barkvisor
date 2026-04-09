import Foundation
import GRDB

public struct AuditEntry: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "audit_log"

    public var id: Int64?
    public var timestamp: String
    public var userId: String?
    public var username: String?
    public var action: String
    public var resourceType: String?
    public var resourceId: String?
    public var resourceName: String?
    public var detail: String?
    public var authMethod: String?
    public var apiKeyId: String?

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let timestamp = Column(CodingKeys.timestamp)
        public static let action = Column(CodingKeys.action)
        public static let resourceType = Column(CodingKeys.resourceType)
    }

    public init(
        id: Int64?,
        timestamp: String,
        userId: String?,
        username: String?,
        action: String,
        resourceType: String?,
        resourceId: String?,
        resourceName: String?,
        detail: String?,
        authMethod: String?,
        apiKeyId: String?,
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userId = userId
        self.username = username
        self.action = action
        self.resourceType = resourceType
        self.resourceId = resourceId
        self.resourceName = resourceName
        self.detail = detail
        self.authMethod = authMethod
        self.apiKeyId = apiKeyId
    }
}
