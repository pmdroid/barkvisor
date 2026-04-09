import Foundation
import GRDB

public struct APIKey: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "api_keys"

    public var id: String
    public var name: String
    public var keyHash: String
    public var keyPrefix: String
    public var userId: String
    public var expiresAt: String?
    public var lastUsedAt: String?
    public var createdAt: String

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let keyHash = Column(CodingKeys.keyHash)
        public static let keyPrefix = Column(CodingKeys.keyPrefix)
        public static let userId = Column(CodingKeys.userId)
        public static let expiresAt = Column(CodingKeys.expiresAt)
        public static let lastUsedAt = Column(CodingKeys.lastUsedAt)
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        guard let date = iso8601.date(from: expiresAt) else {
            Log.auth.warning(
                "Failed to parse API key expiration date: \(expiresAt) — treating as not expired",
            )
            return false
        }
        return date < Date()
    }

    public init(
        id: String,
        name: String,
        keyHash: String,
        keyPrefix: String,
        userId: String,
        expiresAt: String?,
        lastUsedAt: String?,
        createdAt: String,
    ) {
        self.id = id
        self.name = name
        self.keyHash = keyHash
        self.keyPrefix = keyPrefix
        self.userId = userId
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}

public struct APIKeyResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let keyPrefix: String
    public let expiresAt: String?
    public let lastUsedAt: String?
    public let createdAt: String

    public init(
        id: String,
        name: String,
        keyPrefix: String,
        expiresAt: String?,
        lastUsedAt: String?,
        createdAt: String,
    ) {
        self.id = id
        self.name = name
        self.keyPrefix = keyPrefix
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}

public struct APIKeyCreateResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let key: String
    public let keyPrefix: String
    public let expiresAt: String?
    public let createdAt: String

    public init(
        id: String,
        name: String,
        key: String,
        keyPrefix: String,
        expiresAt: String?,
        createdAt: String,
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.keyPrefix = keyPrefix
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}
