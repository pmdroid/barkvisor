#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB

public struct APIKeyCreateResult {
    public let apiKey: APIKey
    public let plaintext: String

    public init(apiKey: APIKey, plaintext: String) {
        self.apiKey = apiKey
        self.plaintext = plaintext
    }
}

public enum APIKeyService {
    /// Compute HMAC-SHA256 of an API key using the API-key HMAC secret, returned as a hex string.
    /// This is used both when creating keys (to store the hash) and when verifying (to look up by hash).
    /// Must not use `Config.jwtSecret` — pairing overwrites that file (PAS-277).
    public static func hmacHash(
        _ plaintext: String,
        secret: String = Config.apiKeyHmacSecret,
    ) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintext.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Check whether a stored hash is a legacy bcrypt hash (starts with "$2").
    public static func isBcryptHash(_ hash: String) -> Bool {
        hash.hasPrefix("$2")
    }

    /// Generate a new API key, hash it with HMAC-SHA256, and store it in the database.
    public static func create(
        name: String,
        expiresIn: String?,
        userId: String,
        db: DatabasePool,
        bytes: [UInt8] = PlatformRandom.secureBytes(count: 32),
        hmacSecret: String? = nil,
    ) async throws -> APIKeyCreateResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BarkVisorError.badRequest("Name is required")
        }

        let randomBytes = bytes.count == 32 ? bytes : PlatformRandom.secureBytes(count: 32)
        let hex = randomBytes.map { String(format: "%02x", $0) }.joined()
        let plaintext = "barkvisor_\(hex)"
        let prefix = String(plaintext.prefix(15))

        let expiresAt = try parseExpiry(expiresIn)
        let now = iso8601.string(from: Date())

        // Hash and insert under the HMAC lock so pairing revokeAll+rotate cannot
        // land between reading the secret and persisting the row.
        return try await Config.withAPIKeyHmacSecretLock {
            let secret = hmacSecret ?? Config.apiKeyHmacSecret
            let hash = hmacHash(plaintext, secret: secret)
            let apiKey = APIKey(
                id: UUID().uuidString,
                name: trimmedName,
                keyHash: hash,
                keyPrefix: prefix,
                userId: userId,
                expiresAt: expiresAt,
                lastUsedAt: nil,
                createdAt: now,
            )
            try await db.write { db in
                try apiKey.insert(db)
            }
            return APIKeyCreateResult(apiKey: apiKey, plaintext: plaintext)
        }
    }

    /// List all API keys for a user.
    public static func list(userId: String, db: DatabasePool) async throws -> [APIKey] {
        try await db.read { db in
            try APIKey.filter(APIKey.Columns.userId == userId).fetchAll(db)
        }
    }

    /// Revoke an API key, verifying ownership. Returns the revoked key.
    public static func revoke(id: String, userId: String, db: DatabasePool) async throws -> APIKey {
        let key = try await db.read { db in
            try APIKey.fetchOne(db, key: id)
        }
        guard let key else {
            throw BarkVisorError.notFound()
        }
        guard key.userId == userId else {
            throw BarkVisorError.forbidden("Cannot revoke another user's key")
        }

        _ = try await db.write { db in
            try APIKey.deleteOne(db, key: id)
        }
        return key
    }

    /// Delete every API key. Pairing overwrites jwt-secret and rotates the
    /// API-key HMAC secret; leftover hashes must not keep working (PAS-277).
    @discardableResult
    public static func revokeAll(db: DatabasePool) async throws -> Int {
        try await db.write { db in
            try APIKey.deleteAll(db)
        }
    }

    /// HMAC hashes created with `jwtSecret` never verify after the first
    /// `api-key-hmac-secret` is generated. Plaintext is not stored, so they
    /// cannot be rehashed. Bcrypt `$2` hashes still upgrade on next use.
    @discardableResult
    public static func revokeUnverifiableHmacKeys(db: DatabasePool) async throws -> Int {
        try await db.write { db in
            let keys = try APIKey.fetchAll(db)
            var removed = 0
            for key in keys where !isBcryptHash(key.keyHash) {
                try key.delete(db)
                removed += 1
            }
            return removed
        }
    }

    /// Drop leftover jwtSecret-keyed HMAC rows until a durable marker exists.
    /// Gating on `ensureAPIKeyHmacSecret().generated` skipped the sweep forever
    /// if the first persist succeeded but this call threw, or if chmod after
    /// the atomic write failed so `generated` stayed false.
    @discardableResult
    public static func revokeUnverifiableKeysIfHmacSecretGenerated(
        db: DatabasePool,
        dataDir: URL,
    ) async throws -> Int {
        try await Config.withAPIKeyHmacSecretLock {
            _ = Config.ensureAPIKeyHmacSecret(in: dataDir)
            guard Config.loadAPIKeyHmacSecret(from: dataDir) != nil else { return 0 }
            if Config.apiKeyHmacMigrationCompleted(in: dataDir) { return 0 }
            let removed = try await revokeUnverifiableHmacKeys(db: db)
            try Config.persistAPIKeyHmacMigrationMarker(to: dataDir)
            if removed > 0 {
                Log.auth.critical(
                    """
                    Dropped \(removed) API key(s) hashed with jwtSecret. \
                    Reissue them; plaintext is not stored so they cannot be rehashed.
                    """,
                )
            }
            return removed
        }
    }

    /// Delete all expired API keys and return how many were removed.
    @discardableResult
    public static func deleteExpired(db: DatabasePool) async throws -> Int {
        let now = iso8601.string(from: Date())
        return try await db.write { db in
            try APIKey
                .filter(APIKey.Columns.expiresAt != nil)
                .filter(APIKey.Columns.expiresAt < now)
                .deleteAll(db)
        }
    }

    /// Parse an expiry duration string ("30d", "1y", "never") into an ISO 8601 date string.
    public static func parseExpiry(_ value: String?) throws -> String? {
        guard let value, value != "never" else { return nil }

        let now = Date()
        let seconds: TimeInterval
        if value.hasSuffix("d"), let days = Int(value.dropLast()) {
            seconds = TimeInterval(days) * 86_400
        } else if value.hasSuffix("y"), let years = Int(value.dropLast()) {
            seconds = TimeInterval(years) * 365.25 * 86_400
        } else {
            throw BarkVisorError.badRequest(
                "Invalid expiresIn format. Use '30d', '90d', '1y', or 'never'",
            )
        }

        return iso8601.string(from: now.addingTimeInterval(seconds))
    }
}
