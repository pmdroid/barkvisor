import CryptoKit
import Foundation
import GRDB

public enum SSHKeyService {
    /// Create a new SSH key record after validating the public key.
    public static func create(name: String, publicKey: String, db: DatabasePool) async throws
        -> SSHKey {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BarkVisorError.badRequest("Name is required")
        }

        let trimmedKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try CloudInitService.validateSSHKey(trimmedKey)

        let keyType = extractKeyType(trimmedKey)
        let fingerprint = computeFingerprint(trimmedKey)

        let now = iso8601.string(from: Date())
        return try await db.write { db -> SSHKey in
            let hasDefault = try SSHKey.filter(Column("isDefault") == true).fetchCount(db) > 0
            let key = SSHKey(
                id: UUID().uuidString,
                name: trimmedName,
                publicKey: trimmedKey,
                fingerprint: fingerprint,
                keyType: keyType,
                isDefault: !hasDefault,
                createdAt: now,
            )
            try key.insert(db)
            return key
        }
    }

    /// Set a key as the default, clearing all other defaults.
    public static func setDefault(id: String, db: DatabasePool) async throws -> SSHKey {
        let updated = try await db.write { db -> SSHKey? in
            try db.execute(sql: "UPDATE ssh_keys SET isDefault = 0")
            guard var key = try SSHKey.fetchOne(db, key: id) else { return nil }
            key.isDefault = true
            try key.update(db)
            return key
        }

        guard let key = updated else {
            throw BarkVisorError.notFound("SSH key not found")
        }
        return key
    }

    /// Delete an SSH key by ID.
    public static func delete(id: String, db: DatabasePool) async throws {
        let deleted = try await db.write { db -> Bool in
            guard let key = try SSHKey.fetchOne(db, key: id) else { return false }
            try key.delete(db)
            return true
        }
        guard deleted else {
            throw BarkVisorError.notFound("SSH key not found")
        }
    }

    /// List all SSH keys, newest first.
    public static func list(db: DatabasePool) async throws -> [SSHKey] {
        try await db.read { db in
            try SSHKey.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    // MARK: - Helpers

    public static func extractKeyType(_ key: String) -> String {
        key.split(separator: " ").first.map(String.init) ?? "unknown"
    }

    public static func computeFingerprint(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let data = Data(base64Encoded: String(parts[1])) else {
            return "unknown"
        }
        let hash = SHA256.hash(data: data)
        let b64 = Data(hash).base64EncodedString()
        let trimmed = b64.replacingOccurrences(of: "=", with: "")
        return "SHA256:\(trimmed)"
    }
}
