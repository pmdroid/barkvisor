import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite("Pairing join admin identity (PAS-285)")
struct PairingJoinAdminTests {
    private func isolatedDir(_ label: String = "join-admin") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDB(_ dir: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }

    @Test func `upsertAdmin matches by id and rejects id username mismatch`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB(dir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try PairingService.upsertAdmin(
            PairingAdminUser(id: "home-admin", username: "pascal", passwordHash: "hashed:first"),
            db: db,
            now: now,
        )
        try PairingService.upsertAdmin(
            PairingAdminUser(id: "home-admin", username: "pascal", passwordHash: "hashed:rotated"),
            db: db,
            now: now,
        )
        let same = try db.read { db in try User.fetchOne(db, key: "home-admin") }
        #expect(same?.username == "pascal")
        #expect(same?.password == "hashed:rotated")

        #expect(throws: PairingError.self) {
            try PairingService.upsertAdmin(
                PairingAdminUser(id: "home-admin", username: "other", passwordHash: "hashed:x"),
                db: db,
                now: now,
            )
        }
        #expect(throws: PairingError.self) {
            try PairingService.upsertAdmin(
                PairingAdminUser(id: "other-admin", username: "pascal", passwordHash: "hashed:y"),
                db: db,
                now: now,
            )
        }
        let users = try db.read { db in try User.fetchAll(db) }
        #expect(users.count == 1)
        #expect(users[0].id == "home-admin")
        #expect(users[0].username == "pascal")
        #expect(users[0].password == "hashed:rotated")
    }
}
