import GRDB
import XCTest
@testable import BarkVisorCore

final class APIKeyServiceTests: XCTestCase {
    private var dbPool: DatabasePool?
    private var tmpDir: URL?

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(dbPool)

        // Seed a user
        try dbPool.write { db in
            let user = User(
                id: "user-1", username: "admin", password: "hashed:test", createdAt: "2025-01-01T00:00:00Z",
            )
            try user.insert(db)
        }
    }

    override func tearDown() {
        dbPool = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - parseExpiry

    func testParseExpiryDays() throws {
        let result = try APIKeyService.parseExpiry("30d")
        XCTAssertNotNil(result)
    }

    func testParseExpiryYears() throws {
        let result = try APIKeyService.parseExpiry("1y")
        XCTAssertNotNil(result)
    }

    func testParseExpiryNever() throws {
        let result = try APIKeyService.parseExpiry("never")
        XCTAssertNil(result)
    }

    func testParseExpiryNil() throws {
        let result = try APIKeyService.parseExpiry(nil)
        XCTAssertNil(result)
    }

    func testParseExpiryInvalidFormat() {
        XCTAssertThrowsError(try APIKeyService.parseExpiry("30h"))
        XCTAssertThrowsError(try APIKeyService.parseExpiry("abc"))
        XCTAssertThrowsError(try APIKeyService.parseExpiry(""))
    }

    // MARK: - create

    func testCreateAPIKey() async throws {
        let result = try await APIKeyService.create(
            name: "Test Key",
            expiresIn: "30d",
            userId: "user-1",
            db: dbPool,
        )

        XCTAssertEqual(result.apiKey.name, "Test Key")
        XCTAssertTrue(result.plaintext.hasPrefix("barkvisor_"))
        XCTAssertEqual(result.plaintext.count, 10 + 64) // "barkvisor_" + 64 hex chars
        XCTAssertEqual(result.apiKey.keyPrefix, String(result.plaintext.prefix(15)))
        XCTAssertNotNil(result.apiKey.expiresAt)
    }

    func testCreateAPIKeyEmptyNameRejected() async {
        do {
            _ = try await APIKeyService.create(
                name: "   ",
                expiresIn: nil,
                userId: "user-1",
                db: dbPool,
            )
            XCTFail("Should throw for empty name")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 400)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - list

    func testListAPIKeys() async throws {
        _ = try await APIKeyService.create(name: "Key 1", expiresIn: nil, userId: "user-1", db: dbPool)
        _ = try await APIKeyService.create(name: "Key 2", expiresIn: nil, userId: "user-1", db: dbPool)

        let keys = try await APIKeyService.list(userId: "user-1", db: dbPool)
        XCTAssertEqual(keys.count, 2)
    }

    // MARK: - revoke

    func testRevokeAPIKey() async throws {
        let created = try await APIKeyService.create(
            name: "Revoke Me", expiresIn: nil, userId: "user-1", db: dbPool,
        )

        let revoked = try await APIKeyService.revoke(
            id: created.apiKey.id, userId: "user-1", db: dbPool,
        )
        XCTAssertEqual(revoked.name, "Revoke Me")

        let remaining = try await APIKeyService.list(userId: "user-1", db: dbPool)
        XCTAssertEqual(remaining.count, 0)
    }

    func testRevokeNonExistentKeyThrows() async {
        do {
            _ = try await APIKeyService.revoke(id: "fake-id", userId: "user-1", db: dbPool)
            XCTFail("Should throw notFound")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 404)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testRevokeOtherUsersKeyForbidden() async throws {
        let created = try await APIKeyService.create(
            name: "Other", expiresIn: nil, userId: "user-1", db: dbPool,
        )

        do {
            _ = try await APIKeyService.revoke(id: created.apiKey.id, userId: "user-2", db: dbPool)
            XCTFail("Should throw forbidden")
        } catch let error as BarkVisorError {
            XCTAssertEqual(error.httpStatus, 403)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - APIKey.isExpired

    func testAPIKeyNotExpiredWhenNil() {
        let key = APIKey(
            id: "k1",
            name: "test",
            keyHash: "h",
            keyPrefix: "p",
            userId: "u1",
            expiresAt: nil,
            lastUsedAt: nil,
            createdAt: "2025-01-01T00:00:00Z",
        )
        XCTAssertFalse(key.isExpired)
    }

    func testAPIKeyExpired() {
        let key = APIKey(
            id: "k1",
            name: "test",
            keyHash: "h",
            keyPrefix: "p",
            userId: "u1",
            expiresAt: "2020-01-01T00:00:00Z",
            lastUsedAt: nil,
            createdAt: "2019-01-01T00:00:00Z",
        )
        XCTAssertTrue(key.isExpired)
    }

    func testAPIKeyNotYetExpired() {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let key = APIKey(
            id: "k1",
            name: "test",
            keyHash: "h",
            keyPrefix: "p",
            userId: "u1",
            expiresAt: future,
            lastUsedAt: nil,
            createdAt: "2025-01-01T00:00:00Z",
        )
        XCTAssertFalse(key.isExpired)
    }
}
