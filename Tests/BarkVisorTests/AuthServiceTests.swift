import Foundation
import GRDB
import JWTKit
import Testing
@testable import BarkVisorCore

private struct TestPasswordHasher: PasswordHasher {
    func hash(_ password: String) throws -> String {
        "hashed:\(password)"
    }
    func verify(_ password: String, against hash: String) throws -> Bool {
        hash == "hashed:\(password)"
    }
}

struct AuthServiceTests {
    private func makeDB() throws -> (URL, DatabasePool) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        let dbPool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(dbPool)
        try dbPool.write { db in
            try User(
                id: "user-1",
                username: "admin",
                password: "hashed:testpass10",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }
        return (tmpDir, dbPool)
    }

    private func makeKeys() async -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "test-secret"), digestAlgorithm: .sha256)
        return keys
    }

    @Test func `login issues jwt and refresh token`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date()
        let session = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        #expect(session.user.username == "admin")
        #expect(session.refreshToken.hasPrefix("bvrt_"))
        let payload = try await keys.verify(session.token, as: UserPayload.self)
        #expect(payload.username == "admin")
        #expect(
            abs(payload.exp.value.timeIntervalSince1970 - now.addingTimeInterval(2 * 60 * 60).timeIntervalSince1970) < 1,
        )
        let stored = try await db.read { db in try RefreshTokenRecord.fetchCount(db) }
        #expect(stored == 1)
        let hash = AuthService.hashRefreshToken(session.refreshToken)
        let row = try await db.read { db in
            try RefreshTokenRecord.filter(RefreshTokenRecord.Columns.tokenHash == hash).fetchOne(db)
        }
        #expect(row != nil)
        #expect(row?.tokenHash != session.refreshToken)
    }

    @Test func `refresh rotates and keeps the family`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        let second = try await AuthService.refresh(
            refreshToken: first.refreshToken,
            keys: keys,
            db: db,
            now: now.addingTimeInterval(60),
        )
        #expect(second.refreshToken != first.refreshToken)
        #expect(second.token != first.token)
        let rows = try await db.read { db in try RefreshTokenRecord.fetchAll(db) }
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.familyId)).count == 1)
        #expect(rows.contains { $0.usedAt != nil })
        #expect(rows.contains { $0.usedAt == nil && $0.revokedAt == nil })
    }

    @Test func `spent refresh drops the family`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        _ = try await AuthService.refresh(
            refreshToken: first.refreshToken,
            keys: keys,
            db: db,
            now: now.addingTimeInterval(60),
        )
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.refresh(
                refreshToken: first.refreshToken,
                keys: keys,
                db: db,
                now: now.addingTimeInterval(120),
            )
        }
        let rows = try await db.read { db in try RefreshTokenRecord.fetchAll(db) }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.revokedAt != nil })
    }

    @Test func `expired refresh fails without rotating`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.refresh(
                refreshToken: first.refreshToken,
                keys: keys,
                db: db,
                now: now.addingTimeInterval(AuthService.refreshTokenTTL + 1),
            )
        }
        let rows = try await db.read { db in try RefreshTokenRecord.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].usedAt == nil)
        #expect(rows[0].revokedAt == nil)
    }

    @Test func `logout revokes the family`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        try await AuthService.revokeRefreshToken(session.refreshToken, db: db, now: now)
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.refresh(
                refreshToken: session.refreshToken,
                keys: keys,
                db: db,
                now: now.addingTimeInterval(10),
            )
        }
        let rows = try await db.read { db in try RefreshTokenRecord.fetchAll(db) }
        #expect(rows.allSatisfy { $0.revokedAt != nil })
    }

    @Test func `revoking one family leaves the other session`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let phone = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        let browser = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        try await AuthService.revokeRefreshToken(phone.refreshToken, db: db, now: now)
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.refresh(
                refreshToken: phone.refreshToken, keys: keys, db: db, now: now,
            )
        }
        let rotated = try await AuthService.refresh(
            refreshToken: browser.refreshToken, keys: keys, db: db, now: now,
        )
        #expect(rotated.refreshToken != browser.refreshToken)
    }

    @Test func `revoke all refresh tokens for the user`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        let b = try await AuthService.loginSession(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now,
        )
        try await AuthService.revokeAllRefreshTokens(userId: "user-1", db: db, now: now)
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.refresh(refreshToken: a.refreshToken, keys: keys, db: db, now: now)
        }
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.refresh(refreshToken: b.refreshToken, keys: keys, db: db, now: now)
        }
    }
}
