import Foundation
import GRDB

public struct LoginOfferRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "login_offers"

    public var id: String
    public var userId: String
    public var codeHash: String
    public var codeDisplay: String
    public var host: String
    public var port: Int
    public var createdAt: String
    public var expiresAt: String
    public var consumedAt: String?

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let userId = Column(CodingKeys.userId)
        public static let codeHash = Column(CodingKeys.codeHash)
        public static let codeDisplay = Column(CodingKeys.codeDisplay)
        public static let host = Column(CodingKeys.host)
        public static let port = Column(CodingKeys.port)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let expiresAt = Column(CodingKeys.expiresAt)
        public static let consumedAt = Column(CodingKeys.consumedAt)
    }

    public init(
        id: String,
        userId: String,
        codeHash: String,
        codeDisplay: String,
        host: String,
        port: Int,
        createdAt: String,
        expiresAt: String,
        consumedAt: String? = nil,
    ) {
        self.id = id
        self.userId = userId
        self.codeHash = codeHash
        self.codeDisplay = codeDisplay
        self.host = host
        self.port = port
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
    }
}

public struct LoginOfferIssue: Codable, Sendable, Equatable {
    public var code: String
    public var expiresAt: String
    public var ttlSeconds: Int
    public var uri: String
    public var host: String
    public var port: Int

    public init(
        code: String,
        expiresAt: String,
        ttlSeconds: Int,
        uri: String,
        host: String,
        port: Int,
    ) {
        self.code = code
        self.expiresAt = expiresAt
        self.ttlSeconds = ttlSeconds
        self.uri = uri
        self.host = host
        self.port = port
    }
}

public struct AuthSessionTokens: Sendable {
    public var token: String
    public var refreshToken: String
    public var user: User

    public init(token: String, refreshToken: String, user: User) {
        self.token = token
        self.refreshToken = refreshToken
        self.user = user
    }
}
