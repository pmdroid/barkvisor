import Foundation
import GRDB

public struct PasskeyCredential: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "passkeys"

    public var id: String
    public var userId: String
    public var credentialId: String
    public var publicKey: Data
    public var signCount: Int
    public var name: String
    public var createdAt: String
    public var lastUsedAt: String?
    public var transports: String?

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let userId = Column(CodingKeys.userId)
        public static let credentialId = Column(CodingKeys.credentialId)
        public static let publicKey = Column(CodingKeys.publicKey)
        public static let signCount = Column(CodingKeys.signCount)
        public static let name = Column(CodingKeys.name)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let lastUsedAt = Column(CodingKeys.lastUsedAt)
        public static let transports = Column(CodingKeys.transports)
    }

    public init(
        id: String,
        userId: String,
        credentialId: String,
        publicKey: Data,
        signCount: Int,
        name: String,
        createdAt: String,
        lastUsedAt: String? = nil,
        transports: String? = nil,
    ) {
        self.id = id
        self.userId = userId
        self.credentialId = credentialId
        self.publicKey = publicKey
        self.signCount = signCount
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.transports = transports
    }

    public var asResponse: PasskeyCredentialResponse {
        PasskeyCredentialResponse(
            id: id,
            name: name,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            credentialId: credentialId,
        )
    }
}

public struct PasskeyCredentialResponse: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let createdAt: String
    public let lastUsedAt: String?
    public let credentialId: String

    public init(
        id: String,
        name: String,
        createdAt: String,
        lastUsedAt: String?,
        credentialId: String,
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.credentialId = credentialId
    }
}
