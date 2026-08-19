import Foundation
import GRDB

public struct RefreshTokenRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "refresh_tokens"

    public var id: String
    public var userId: String
    public var familyId: String
    public var tokenHash: String
    public var createdAt: String
    public var expiresAt: String
    public var usedAt: String?
    public var revokedAt: String?

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let userId = Column(CodingKeys.userId)
        public static let familyId = Column(CodingKeys.familyId)
        public static let tokenHash = Column(CodingKeys.tokenHash)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let expiresAt = Column(CodingKeys.expiresAt)
        public static let usedAt = Column(CodingKeys.usedAt)
        public static let revokedAt = Column(CodingKeys.revokedAt)
    }

    public init(
        id: String,
        userId: String,
        familyId: String,
        tokenHash: String,
        createdAt: String,
        expiresAt: String,
        usedAt: String? = nil,
        revokedAt: String? = nil,
    ) {
        self.id = id
        self.userId = userId
        self.familyId = familyId
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.usedAt = usedAt
        self.revokedAt = revokedAt
    }
}
