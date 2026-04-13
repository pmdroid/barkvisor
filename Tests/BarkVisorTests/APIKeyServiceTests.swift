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
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
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
