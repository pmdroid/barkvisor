import Foundation
import GRDB

public struct UserTOTPRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "user_totp"

    public var userId: String
    public var secret: String?
    public var pendingSecret: String?
    public var pendingCreatedAt: String?
    public var enabledAt: String?
    public var lastUsedCounter: Int64?

    public enum Columns {
        public static let userId = Column(CodingKeys.userId)
        public static let secret = Column(CodingKeys.secret)
        public static let pendingSecret = Column(CodingKeys.pendingSecret)
        public static let pendingCreatedAt = Column(CodingKeys.pendingCreatedAt)
        public static let enabledAt = Column(CodingKeys.enabledAt)
        public static let lastUsedCounter = Column(CodingKeys.lastUsedCounter)
    }

    public init(
        userId: String,
        secret: String? = nil,
        pendingSecret: String? = nil,
        pendingCreatedAt: String? = nil,
        enabledAt: String? = nil,
        lastUsedCounter: Int64? = nil,
    ) {
        self.userId = userId
        self.secret = secret
        self.pendingSecret = pendingSecret
        self.pendingCreatedAt = pendingCreatedAt
        self.enabledAt = enabledAt
        self.lastUsedCounter = lastUsedCounter
    }
}

public struct TOTPRecoveryCodeRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "totp_recovery_codes"

    public var id: String
    public var userId: String
    public var codeHash: String
    public var createdAt: String
    public var usedAt: String?

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let userId = Column(CodingKeys.userId)
        public static let codeHash = Column(CodingKeys.codeHash)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let usedAt = Column(CodingKeys.usedAt)
    }

    public init(
        id: String,
        userId: String,
        codeHash: String,
        createdAt: String,
        usedAt: String? = nil,
    ) {
        self.id = id
        self.userId = userId
        self.codeHash = codeHash
        self.createdAt = createdAt
        self.usedAt = usedAt
    }
}

public struct LoginChallengeRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "login_challenges"

    public var id: String
    public var userId: String
    public var tokenHash: String
    public var createdAt: String
    public var expiresAt: String
    public var consumedAt: String?
    public var attempts: Int

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let userId = Column(CodingKeys.userId)
        public static let tokenHash = Column(CodingKeys.tokenHash)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let expiresAt = Column(CodingKeys.expiresAt)
        public static let consumedAt = Column(CodingKeys.consumedAt)
        public static let attempts = Column(CodingKeys.attempts)
    }

    public init(
        id: String,
        userId: String,
        tokenHash: String,
        createdAt: String,
        expiresAt: String,
        consumedAt: String? = nil,
        attempts: Int = 0,
    ) {
        self.id = id
        self.userId = userId
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.attempts = attempts
    }
}

public struct TOTPStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var pending: Bool
    public var recoveryCodesRemaining: Int
    public var enabledAt: String?

    public init(enabled: Bool, pending: Bool, recoveryCodesRemaining: Int, enabledAt: String?) {
        self.enabled = enabled
        self.pending = pending
        self.recoveryCodesRemaining = recoveryCodesRemaining
        self.enabledAt = enabledAt
    }
}

public struct TOTPSetup: Codable, Sendable, Equatable {
    public var secret: String
    public var otpauthUrl: String
    public var issuer: String
    public var account: String

    public init(secret: String, otpauthUrl: String, issuer: String, account: String) {
        self.secret = secret
        self.otpauthUrl = otpauthUrl
        self.issuer = issuer
        self.account = account
    }
}

public struct TOTPRecoveryCodes: Codable, Sendable, Equatable {
    public var recoveryCodes: [String]

    public init(recoveryCodes: [String]) {
        self.recoveryCodes = recoveryCodes
    }
}

public struct LoginChallengeIssued: Sendable, Equatable {
    public var challengeToken: String
    public var expiresAt: String

    public init(challengeToken: String, expiresAt: String) {
        self.challengeToken = challengeToken
        self.expiresAt = expiresAt
    }
}

public enum PasswordLoginResult: Sendable {
    case session(AuthSessionTokens)
    case totpChallenge(LoginChallengeIssued)
}
