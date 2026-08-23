import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class APIKeyServiceTests {
    private var dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbPool)

        try dbPool.write { db in
            let user = User(
                id: "user-1", username: "admin", password: "hashed:test", createdAt: "2025-01-01T00:00:00Z",
            )
            try user.insert(db)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - parseExpiry

    @Test func `parse expiry days`() throws {
        let result = try APIKeyService.parseExpiry("30d")
        #expect(result != nil)
    }

    @Test func `parse expiry years`() throws {
        let result = try APIKeyService.parseExpiry("1y")
        #expect(result != nil)
    }

    @Test func `parse expiry never`() throws {
        let result = try APIKeyService.parseExpiry("never")
        #expect(result == nil)
    }

    @Test func `parse expiry nil`() throws {
        let result = try APIKeyService.parseExpiry(nil)
        #expect(result == nil)
    }

    @Test func `parse expiry invalid format`() {
        #expect(throws: (any Error).self) { try APIKeyService.parseExpiry("30h") }
        #expect(throws: (any Error).self) { try APIKeyService.parseExpiry("abc") }
        #expect(throws: (any Error).self) { try APIKeyService.parseExpiry("") }
    }

    // MARK: - create

    @Test func `create API key`() async throws {
        let result = try await APIKeyService.create(
            name: "Test Key", expiresIn: "30d", userId: "user-1", db: dbPool,
        )
        #expect(result.apiKey.name == "Test Key")
        #expect(result.plaintext.hasPrefix("barkvisor_"))
        #expect(result.plaintext.count == 10 + 64)
        #expect(result.apiKey.keyPrefix == String(result.plaintext.prefix(15)))
        #expect(result.apiKey.expiresAt != nil)
    }

    @Test func `create API key empty name rejected`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await APIKeyService.create(name: "   ", expiresIn: nil, userId: "user-1", db: dbPool)
        }
        #expect(error?.httpStatus == 400)
    }

    @Test func `hmac hash does not use jwt secret`() {
        let plaintext = "barkvisor_" + String(repeating: "ab", count: 32)
        let jwt = "jwt-secret-material"
        let api = "api-key-hmac-material"
        let apiHash = APIKeyService.hmacHash(plaintext, secret: api)
        let jwtHash = APIKeyService.hmacHash(plaintext, secret: jwt)
        #expect(apiHash != jwtHash)
        #expect(apiHash == APIKeyService.hmacHash(plaintext, secret: api))
        #expect(apiHash.count == 64)
    }

    @Test func `create hashes with api key hmac secret not jwt secret`() async throws {
        let hmac = "api-hmac-test-secret"
        let jwt = "jwt-test-secret"
        let bytes = [UInt8](repeating: 0x11, count: 32)
        let result = try await APIKeyService.create(
            name: "Hashed",
            expiresIn: nil,
            userId: "user-1",
            db: dbPool,
            bytes: bytes,
            hmacSecret: hmac,
        )
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        #expect(result.plaintext == "barkvisor_\(hex)")
        #expect(result.apiKey.keyHash == APIKeyService.hmacHash(result.plaintext, secret: hmac))
        #expect(result.apiKey.keyHash != APIKeyService.hmacHash(result.plaintext, secret: jwt))
    }

    @Test func `create ignores non 32 byte material and still yields 32 raw bytes`() async throws {
        let result = try await APIKeyService.create(
            name: "Short",
            expiresIn: nil,
            userId: "user-1",
            db: dbPool,
            bytes: [0x01, 0x02],
            hmacSecret: "test-hmac",
        )
        #expect(result.plaintext.hasPrefix("barkvisor_"))
        #expect(result.plaintext.count == 10 + 64)
        #expect(result.plaintext != "barkvisor_0102")
    }

    // MARK: - list

    @Test func `list API keys`() async throws {
        _ = try await APIKeyService.create(name: "Key 1", expiresIn: nil, userId: "user-1", db: dbPool)
        _ = try await APIKeyService.create(name: "Key 2", expiresIn: nil, userId: "user-1", db: dbPool)
        let keys = try await APIKeyService.list(userId: "user-1", db: dbPool)
        #expect(keys.count == 2)
    }

    // MARK: - revoke

    @Test func `revoke API key`() async throws {
        let created = try await APIKeyService.create(
            name: "Revoke Me", expiresIn: nil, userId: "user-1", db: dbPool,
        )
        let revoked = try await APIKeyService.revoke(id: created.apiKey.id, userId: "user-1", db: dbPool)
        #expect(revoked.name == "Revoke Me")
        let remaining = try await APIKeyService.list(userId: "user-1", db: dbPool)
        #expect(remaining.isEmpty)
    }

    @Test func `revoke non existent key throws`() async {
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await APIKeyService.revoke(id: "fake-id", userId: "user-1", db: dbPool)
        }
        #expect(error?.httpStatus == 404)
    }

    @Test func `revoke other users key forbidden`() async throws {
        let created = try await APIKeyService.create(
            name: "Other", expiresIn: nil, userId: "user-1", db: dbPool,
        )
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await APIKeyService.revoke(id: created.apiKey.id, userId: "user-2", db: dbPool)
        }
        #expect(error?.httpStatus == 403)
    }

    @Test func `revoke all deletes every key`() async throws {
        _ = try await APIKeyService.create(
            name: "A", expiresIn: nil, userId: "user-1", db: dbPool, hmacSecret: "s",
        )
        _ = try await APIKeyService.create(
            name: "B", expiresIn: nil, userId: "user-1", db: dbPool, hmacSecret: "s",
        )
        let removed = try await APIKeyService.revokeAll(db: dbPool)
        #expect(removed == 2)
        #expect(try await APIKeyService.list(userId: "user-1", db: dbPool).isEmpty)
    }

    @Test func `first hmac secret generation drops jwtSecret hashed keys`() async throws {
        try await insertKey(id: "hmac-dead", name: "Dead HMAC", hash: "abc123notbcrypt")
        try await insertKey(id: "bcrypt-keep", name: "Legacy bcrypt", hash: "$2b$10$legacyhash")

        let removed = try await APIKeyService.revokeUnverifiableKeysIfHmacSecretGenerated(
            db: dbPool, dataDir: tmpDir,
        )
        #expect(removed == 1)
        let remaining = try await APIKeyService.list(userId: "user-1", db: dbPool)
        #expect(Set(remaining.map(\.id)) == ["bcrypt-keep"])
        #expect(Config.loadAPIKeyHmacSecret(from: tmpDir) != nil)
    }

    @Test func `existing hmac secret leaves stored keys listed`() async throws {
        try Config.persistAPIKeyHmacSecret("already-there", to: tmpDir)
        try await insertKey(id: "live-hmac", name: "Live", hash: "deadbeefcafebabe")

        let removed = try await APIKeyService.revokeUnverifiableKeysIfHmacSecretGenerated(
            db: dbPool, dataDir: tmpDir,
        )
        #expect(removed == 0)
        let remaining = try await APIKeyService.list(userId: "user-1", db: dbPool)
        #expect(Set(remaining.map(\.id)) == ["live-hmac"])
    }

    @Test func `first hmac secret generation with empty table is a no-op`() async throws {
        let removed = try await APIKeyService.revokeUnverifiableKeysIfHmacSecretGenerated(
            db: dbPool, dataDir: tmpDir,
        )
        #expect(removed == 0)
        #expect(try await APIKeyService.list(userId: "user-1", db: dbPool).isEmpty)
    }

    private func insertKey(id: String, name: String, hash: String) async throws {
        let key = APIKey(
            id: id, name: name, keyHash: hash, keyPrefix: "barkvisor_abcde",
            userId: "user-1", expiresAt: nil, lastUsedAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        try await dbPool.write { db in
            try key.insert(db)
        }
    }

    // MARK: - APIKey.isExpired

    @Test func `api key not expired when nil`() {
        let key = APIKey(
            id: "k1", name: "test", keyHash: "h", keyPrefix: "p", userId: "u1",
            expiresAt: nil, lastUsedAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        #expect(!key.isExpired)
    }

    @Test func `api key expired`() {
        let key = APIKey(
            id: "k1", name: "test", keyHash: "h", keyPrefix: "p", userId: "u1",
            expiresAt: "2020-01-01T00:00:00Z", lastUsedAt: nil, createdAt: "2019-01-01T00:00:00Z",
        )
        #expect(key.isExpired)
    }

    @Test func `api key not yet expired`() {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let key = APIKey(
            id: "k1", name: "test", keyHash: "h", keyPrefix: "p", userId: "u1",
            expiresAt: future, lastUsedAt: nil, createdAt: "2025-01-01T00:00:00Z",
        )
        #expect(!key.isExpired)
    }
}
