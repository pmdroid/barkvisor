#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB

public enum TOTPService {
    public static let pendingTTL: TimeInterval = 10 * 60
    public static let challengeTTL: TimeInterval = 5 * 60
    public static let maxChallengeAttempts = 5
    public static let recoveryCodeCount = 10

    public static func status(userId: String, db: DatabasePool, now: Date = Date()) async throws -> TOTPStatus {
        try await db.read { db in
            let row = try UserTOTPRecord.fetchOne(db, key: userId)
            let remaining = try unusedRecoveryCount(userId: userId, db: db)
            let pending = isPending(row, now: now)
            return TOTPStatus(
                enabled: row?.secret != nil && row?.enabledAt != nil,
                pending: pending,
                recoveryCodesRemaining: remaining,
                enabledAt: row?.enabledAt,
            )
        }
    }

    public static func isEnabled(userId: String, db: DatabasePool) async throws -> Bool {
        try await db.read { db in
            guard let row = try UserTOTPRecord.fetchOne(db, key: userId) else { return false }
            return row.secret != nil && row.enabledAt != nil
        }
    }

    public static func beginSetup(
        userId: String,
        username: String,
        db: DatabasePool,
        now: Date = Date(),
        secret: String? = nil,
    ) async throws -> TOTPSetup {
        let issued = secret ?? TOTP.generateSecret()
        guard Base32.decode(issued) != nil else {
            throw BarkVisorError.internalError("Invalid TOTP secret")
        }
        try await db.write { db in
            if let existing = try UserTOTPRecord.fetchOne(db, key: userId),
               existing.secret != nil, existing.enabledAt != nil {
                throw BarkVisorError.conflict("Two-factor authentication is already enabled")
            }
            var row = try UserTOTPRecord.fetchOne(db, key: userId) ?? UserTOTPRecord(userId: userId)
            row.pendingSecret = issued
            row.pendingCreatedAt = iso8601.string(from: now)
            try row.save(db)
        }
        return TOTPSetup(
            secret: issued,
            otpauthUrl: TOTP.otpauthURL(secret: issued, account: username),
            issuer: TOTP.issuer,
            account: username,
        )
    }

    public static func confirmSetup(
        userId: String,
        code: String,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws -> TOTPRecoveryCodes {
        let codes = generateRecoveryCodes()
        try await db.write { db in
            guard var row = try UserTOTPRecord.fetchOne(db, key: userId) else {
                throw BarkVisorError.badRequest("Two-factor setup has not been started")
            }
            if row.secret != nil, row.enabledAt != nil {
                throw BarkVisorError.conflict("Two-factor authentication is already enabled")
            }
            guard isPending(row, now: now), let pending = row.pendingSecret, let secretData = Base32.decode(pending)
            else {
                throw BarkVisorError.badRequest("Two-factor setup expired. Start again.")
            }
            guard let matched = TOTP.verify(code: code, secret: secretData, at: now) else {
                throw BarkVisorError.unauthorized("Invalid authenticator code")
            }
            row.secret = pending
            row.pendingSecret = nil
            row.pendingCreatedAt = nil
            row.enabledAt = iso8601.string(from: now)
            row.lastUsedCounter = Int64(bitPattern: matched)
            try row.update(db)
            try replaceRecoveryCodes(userId: userId, codes: codes, now: now, db: db)
        }
        return TOTPRecoveryCodes(recoveryCodes: codes)
    }

    public static func disable(
        userId: String,
        code: String,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws {
        try await db.write { db in
            try consumeSecondFactor(userId: userId, code: code, now: now, db: db)
            try TOTPRecoveryCodeRecord
                .filter(TOTPRecoveryCodeRecord.Columns.userId == userId)
                .deleteAll(db)
            try LoginChallengeRecord
                .filter(LoginChallengeRecord.Columns.userId == userId)
                .deleteAll(db)
            try UserTOTPRecord.deleteOne(db, key: userId)
        }
    }

    public static func regenerateRecoveryCodes(
        userId: String,
        code: String,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws -> TOTPRecoveryCodes {
        let codes = generateRecoveryCodes()
        try await db.write { db in
            try consumeSecondFactor(userId: userId, code: code, now: now, db: db, allowRecovery: false)
            try replaceRecoveryCodes(userId: userId, codes: codes, now: now, db: db)
        }
        return TOTPRecoveryCodes(recoveryCodes: codes)
    }

    public static func issueLoginChallenge(
        userId: String,
        db: DatabasePool,
        now: Date = Date(),
        ttl: TimeInterval = challengeTTL,
    ) async throws -> LoginChallengeIssued {
        let plaintext = generateChallengeToken()
        let expires = now.addingTimeInterval(ttl)
        let record = LoginChallengeRecord(
            id: UUID().uuidString,
            userId: userId,
            tokenHash: hashToken(plaintext),
            createdAt: iso8601.string(from: now),
            expiresAt: iso8601.string(from: expires),
        )
        try await db.write { db in
            try LoginChallengeRecord
                .filter(LoginChallengeRecord.Columns.userId == userId)
                .filter(LoginChallengeRecord.Columns.consumedAt == nil)
                .deleteAll(db)
            try record.insert(db)
        }
        return LoginChallengeIssued(challengeToken: plaintext, expiresAt: iso8601.string(from: expires))
    }

    public static func consumeLoginChallenge(
        token: String,
        code: String,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws -> User {
        try await db.write { db in
            let presented = hashToken(token)
            guard var challenge = try LoginChallengeRecord
                .filter(LoginChallengeRecord.Columns.tokenHash == presented)
                .fetchOne(db)
            else {
                throw BarkVisorError.unauthorized("Invalid or expired sign-in challenge")
            }
            if challenge.consumedAt != nil {
                throw BarkVisorError.unauthorized("Invalid or expired sign-in challenge")
            }
            guard let expires = iso8601.date(from: challenge.expiresAt), now < expires else {
                challenge.consumedAt = iso8601.string(from: now)
                try challenge.update(db)
                throw BarkVisorError.unauthorized("Invalid or expired sign-in challenge")
            }
            if challenge.attempts >= maxChallengeAttempts {
                challenge.consumedAt = iso8601.string(from: now)
                try challenge.update(db)
                throw BarkVisorError.unauthorized("Invalid authenticator code")
            }

            do {
                try consumeSecondFactor(userId: challenge.userId, code: code, now: now, db: db)
            } catch {
                challenge.attempts += 1
                if challenge.attempts >= maxChallengeAttempts {
                    challenge.consumedAt = iso8601.string(from: now)
                }
                try challenge.update(db)
                throw error
            }

            challenge.consumedAt = iso8601.string(from: now)
            try challenge.update(db)
            guard let user = try User.filter(User.Columns.id == challenge.userId).fetchOne(db) else {
                throw BarkVisorError.unauthorized("Invalid or expired sign-in challenge")
            }
            return user
        }
    }

    public static func generateRecoveryCodes(
        count: Int = recoveryCodeCount,
        bytes: [[UInt8]]? = nil,
    ) -> [String] {
        (0 ..< count).map { i in
            let raw: [UInt8] =
                if let bytes, i < bytes.count {
                    bytes[i]
                } else {
                    PlatformRandom.secureBytes(count: 8)
                }
            let hex = raw.map { String(format: "%02x", $0) }.joined()
            return formatRecoveryCode(hex)
        }
    }

    public static func normalizeRecoveryCode(_ code: String) -> String {
        code.lowercased().filter(\.isHexDigit)
    }

    public static func hashToken(_ plaintext: String) -> String {
        SHA256.hash(data: Data(plaintext.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func hashRecoveryCode(_ code: String) -> String {
        hashToken(normalizeRecoveryCode(code))
    }

    public static func generateChallengeToken(
        bytes: [UInt8] = PlatformRandom.secureBytes(count: 32),
    ) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "bvch_\(hex)"
    }

    // MARK: - Private

    private static func formatRecoveryCode(_ hex: String) -> String {
        let compact = normalizeRecoveryCode(hex)
        var groups: [String] = []
        var rest = compact[...]
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: "-")
    }

    private static func isPending(_ row: UserTOTPRecord?, now: Date) -> Bool {
        guard let row, let pending = row.pendingSecret, !pending.isEmpty,
              let created = row.pendingCreatedAt.flatMap({ iso8601.date(from: $0) })
        else { return false }
        return now.timeIntervalSince(created) < pendingTTL
    }

    private static func unusedRecoveryCount(userId: String, db: GRDB.Database) throws -> Int {
        try TOTPRecoveryCodeRecord
            .filter(TOTPRecoveryCodeRecord.Columns.userId == userId)
            .filter(TOTPRecoveryCodeRecord.Columns.usedAt == nil)
            .fetchCount(db)
    }

    private static func replaceRecoveryCodes(
        userId: String,
        codes: [String],
        now: Date,
        db: GRDB.Database,
    ) throws {
        try TOTPRecoveryCodeRecord
            .filter(TOTPRecoveryCodeRecord.Columns.userId == userId)
            .deleteAll(db)
        let stamp = iso8601.string(from: now)
        for code in codes {
            let row = TOTPRecoveryCodeRecord(
                id: UUID().uuidString,
                userId: userId,
                codeHash: hashRecoveryCode(code),
                createdAt: stamp,
            )
            try row.insert(db)
        }
    }

    private static func consumeSecondFactor(
        userId: String,
        code: String,
        now: Date,
        db: GRDB.Database,
        allowRecovery: Bool = true,
    ) throws {
        guard var row = try UserTOTPRecord.fetchOne(db, key: userId),
              let secret = row.secret, let secretData = Base32.decode(secret),
              row.enabledAt != nil
        else {
            throw BarkVisorError.badRequest("Two-factor authentication is not enabled")
        }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = trimmed.filter(\.isNumber)
        let looksLikeTOTP = digitsOnly.count == TOTP.digits
            && trimmed.lowercased().allSatisfy { $0.isNumber || $0.isWhitespace }

        if looksLikeTOTP {
            let last = row.lastUsedCounter.map { UInt64(bitPattern: $0) }
            guard let matched = TOTP.verify(
                code: digitsOnly, secret: secretData, at: now, lastUsedCounter: last,
            ) else {
                throw BarkVisorError.unauthorized("Invalid authenticator code")
            }
            row.lastUsedCounter = Int64(bitPattern: matched)
            try row.update(db)
            return
        }

        guard allowRecovery else {
            throw BarkVisorError.unauthorized("Invalid authenticator code")
        }

        let normalized = normalizeRecoveryCode(trimmed)
        guard normalized.count == 16 else {
            throw BarkVisorError.unauthorized("Invalid authenticator code")
        }
        let presented = hashRecoveryCode(normalized)
        guard var recovery = try TOTPRecoveryCodeRecord
            .filter(TOTPRecoveryCodeRecord.Columns.userId == userId)
            .filter(TOTPRecoveryCodeRecord.Columns.codeHash == presented)
            .fetchOne(db)
        else {
            throw BarkVisorError.unauthorized("Invalid authenticator code")
        }
        if recovery.usedAt != nil {
            throw BarkVisorError.unauthorized("Invalid authenticator code")
        }
        recovery.usedAt = iso8601.string(from: now)
        try recovery.update(db)
    }
}
