import CryptoKit
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
    /// Compute HMAC-SHA256 of an API key using the JWT secret, returned as a hex string.
    /// This is used both when creating keys (to store the hash) and when verifying (to look up by hash).
    public static func hmacHash(_ plaintext: String) -> String {
        let key = SymmetricKey(data: Data(Config.jwtSecret.utf8))
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
    ) async throws -> APIKeyCreateResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BarkVisorError.badRequest("Name is required")
        }

        // Generate random key
        let randomBytes = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
        let hex = randomBytes.map { String(format: "%02x", $0) }.joined()
        let plaintext = "barkvisor_\(hex)"
        let prefix = String(plaintext.prefix(15))

        let expiresAt = try parseExpiry(expiresIn)
        let now = iso8601.string(from: Date())
        let hash = hmacHash(plaintext)

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
