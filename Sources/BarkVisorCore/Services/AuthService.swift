#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB
import JWTKit

public enum AuthService {
    public static let accessTokenTTL: TimeInterval = 2 * 60 * 60
    public static let refreshTokenTTL: TimeInterval = 30 * 24 * 60 * 60
    /// Home→Device mTLS hop. Verified on arrival, so this only covers RTT.
    public static let memberHopTokenTTL: TimeInterval = 2 * 60

    /// Authenticate a user with username/password. Returns a signed JWT token.
    public static func login(
        username: String,
        password: String,
        hasher: PasswordHasher,
        keys: JWTKeyCollection,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws -> (token: String, user: User) {
        let user = try await db.read { db in
            try User.filter(User.Columns.username == username).fetchOne(db)
        }

        // Always perform a bcrypt verify to prevent user-enumeration via timing.
        let dummyHash = "$2b$12$000000000000000000000uKsfROku1VKyeVROaku1VKyeVROaku1a"
        let hashToVerify: String =
            if let userPassword = user?.password, !userPassword.isEmpty {
                userPassword
            } else {
                dummyHash
            }
        let passwordMatch = try hasher.verify(password, against: hashToVerify)

        guard let user else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }

        guard !user.password.isEmpty else {
            throw BarkVisorError.forbidden(
                "Password not yet configured. Complete onboarding setup first.",
            )
        }

        guard passwordMatch else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }

        let token = try await signAccessToken(user: user, keys: keys, now: now)
        return (token, user)
    }

    public static func loginSession(
        username: String,
        password: String,
        hasher: PasswordHasher,
        keys: JWTKeyCollection,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws -> AuthSessionTokens {
        let (token, user) = try await login(
            username: username,
            password: password,
            hasher: hasher,
            keys: keys,
            db: db,
            now: now,
        )
        let refresh = try await issueRefreshToken(userId: user.id, db: db, now: now)
        return AuthSessionTokens(token: token, refreshToken: refresh, user: user)
    }

    public static func signAccessToken(
        user: User,
        keys: JWTKeyCollection,
        now: Date = Date(),
    ) async throws -> String {
        let payload = UserPayload(
            sub: .init(value: user.id),
            username: user.username,
            exp: .init(value: now.addingTimeInterval(accessTokenTTL)),
            role: user.userRole.rawValue,
        )
        return try await keys.sign(payload)
    }

    /// Inference API keys belong to an admin User but must stay inference on members.
    public static func memberHopRole(
        userRole: String,
        authMethod: String,
        apiKeyKind: String?,
    ) -> String {
        if OllamaAuthPolicy.principal(
            userRole: userRole,
            authMethod: authMethod,
            apiKeyKind: apiKeyKind,
        ) == .inferenceKey {
            return UserRole.inference.rawValue
        }
        return UserRolePolicy.parseStored(userRole).rawValue
    }

    /// Short-lived Home JWT for a member Device hop. API keys are Home-local.
    public static func signMemberHopToken(
        userId: String,
        username: String,
        role: String,
        keys: JWTKeyCollection,
        now: Date = Date(),
        ttl: TimeInterval = memberHopTokenTTL,
    ) async throws -> String {
        let payload = UserPayload(
            sub: .init(value: userId),
            username: username,
            exp: .init(value: now.addingTimeInterval(ttl)),
            role: role,
        )
        return try await keys.sign(payload)
    }

    public static func hashRefreshToken(_ plaintext: String) -> String {
        SHA256.hash(data: Data(plaintext.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func generateRefreshToken(
        bytes: [UInt8] = PlatformRandom.secureBytes(count: 32),
    ) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "bvrt_\(hex)"
    }

    public static func issueRefreshToken(
        userId: String,
        db: DatabasePool,
        now: Date = Date(),
        ttl: TimeInterval = refreshTokenTTL,
        familyId: String = UUID().uuidString,
    ) async throws -> String {
        let plaintext = generateRefreshToken()
        let record = RefreshTokenRecord(
            id: UUID().uuidString,
            userId: userId,
            familyId: familyId,
            tokenHash: hashRefreshToken(plaintext),
            createdAt: iso8601.string(from: now),
            expiresAt: iso8601.string(from: now.addingTimeInterval(ttl)),
        )
        try await db.write { db in
            try record.insert(db)
        }
        return plaintext
    }

    public static func refresh(
        refreshToken: String,
        keys: JWTKeyCollection,
        db: DatabasePool,
        now: Date = Date(),
        ttl: TimeInterval = refreshTokenTTL,
    ) async throws -> AuthSessionTokens {
        let presentedHash = hashRefreshToken(refreshToken)
        enum Outcome {
            case rotated(user: User, refresh: String)
            case reject(String)
        }
        let outcome = try await db.write { db -> Outcome in
            guard let existing = try RefreshTokenRecord
                .filter(RefreshTokenRecord.Columns.tokenHash == presentedHash)
                .fetchOne(db)
            else {
                return .reject("Invalid refresh token")
            }
            if existing.revokedAt != nil {
                return .reject("Invalid refresh token")
            }
            if existing.usedAt != nil {
                try revokeFamilyLocked(familyId: existing.familyId, now: now, db: db)
                return .reject("Refresh token already used")
            }
            guard let expires = iso8601.date(from: existing.expiresAt), now < expires else {
                return .reject("Refresh token expired")
            }
            guard let user = try User.filter(User.Columns.id == existing.userId).fetchOne(db) else {
                return .reject("Invalid refresh token")
            }

            var spent = existing
            spent.usedAt = iso8601.string(from: now)
            try spent.update(db)

            let plaintext = generateRefreshToken()
            let next = RefreshTokenRecord(
                id: UUID().uuidString,
                userId: existing.userId,
                familyId: existing.familyId,
                tokenHash: hashRefreshToken(plaintext),
                createdAt: iso8601.string(from: now),
                expiresAt: iso8601.string(from: now.addingTimeInterval(ttl)),
            )
            try next.insert(db)
            return .rotated(user: user, refresh: plaintext)
        }
        switch outcome {
        case let .reject(reason):
            throw BarkVisorError.unauthorized(reason)
        case let .rotated(user, refresh):
            let token = try await signAccessToken(user: user, keys: keys, now: now)
            return AuthSessionTokens(token: token, refreshToken: refresh, user: user)
        }
    }

    public static func revokeRefreshToken(
        _ refreshToken: String,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws {
        let presentedHash = hashRefreshToken(refreshToken)
        try await db.write { db in
            guard let existing = try RefreshTokenRecord
                .filter(RefreshTokenRecord.Columns.tokenHash == presentedHash)
                .fetchOne(db)
            else {
                return
            }
            try revokeFamilyLocked(familyId: existing.familyId, now: now, db: db)
        }
    }

    public static func revokeAllRefreshTokens(
        userId: String,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws {
        try await db.write { db in
            let rows = try RefreshTokenRecord
                .filter(RefreshTokenRecord.Columns.userId == userId)
                .filter(RefreshTokenRecord.Columns.revokedAt == nil)
                .fetchAll(db)
            let stamp = iso8601.string(from: now)
            for var row in rows {
                row.revokedAt = stamp
                try row.update(db)
            }
        }
    }

    private static func revokeFamilyLocked(
        familyId: String,
        now: Date,
        db: GRDB.Database,
    ) throws {
        let rows = try RefreshTokenRecord
            .filter(RefreshTokenRecord.Columns.familyId == familyId)
            .filter(RefreshTokenRecord.Columns.revokedAt == nil)
            .fetchAll(db)
        let stamp = iso8601.string(from: now)
        for var row in rows {
            row.revokedAt = stamp
            try row.update(db)
        }
    }
}
