import Foundation
import GRDB
import JWTKit
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

    @Test func `username collision rejects before swapping jwt secret or keyring`() async throws {
        let dir = try isolatedDir("join-admin-collision")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB(dir)
        try await db.write { db in
            try User(
                id: UUID().uuidString,
                username: "pascal",
                password: "hashed:local",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        try Config.persistJWTSecret("joiner-old-secret", to: dir)
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "joiner-old-secret"), digestAlgorithm: .sha256)
        let localToken = try await keys.sign(
            UserPayload(
                sub: .init(value: "local-admin"),
                username: "pascal",
                exp: .init(value: Date().addingTimeInterval(3_600)),
            ),
        )

        let response = PairingRedeemResponse(
            hostId: "issuer",
            deviceCertificatePEM: "x",
            deviceFingerprint: "y",
            caCertificatePEM: "z",
            caFingerprint: "c",
            issuedCertificatePEM: "i",
            issuedFingerprint: "f",
            agentPort: 7_778,
            jwtSecret: "issuer-new-secret",
            adminUser: PairingAdminUser(
                id: UUID().uuidString,
                username: "pascal",
                passwordHash: "hashed:issuer",
            ),
        )
        await #expect(throws: PairingError.self) {
            try await PairingService.applySharedIdentity(
                response,
                dataDir: dir,
                now: Date(timeIntervalSince1970: 1_700_000_000),
                db: db,
                keys: keys,
            )
        }

        #expect(Config.loadJWTSecret(from: dir) == "joiner-old-secret")
        let users = try await db.read { db in try User.fetchAll(db) }
        #expect(users.count == 1)
        #expect(users[0].username == "pascal")
        #expect(users[0].password == "hashed:local")
        let verified = try await keys.verify(localToken, as: UserPayload.self)
        #expect(verified.username == "pascal")
    }

    @Test func `id username mismatch rejects before swapping jwt secret`() async throws {
        let dir = try isolatedDir("join-admin-id-mismatch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB(dir)
        try await db.write { db in
            try User(
                id: "home-admin",
                username: "pascal",
                password: "hashed:local",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        try Config.persistJWTSecret("joiner-old-secret", to: dir)

        let response = PairingRedeemResponse(
            hostId: "issuer",
            deviceCertificatePEM: "x",
            deviceFingerprint: "y",
            caCertificatePEM: "z",
            caFingerprint: "c",
            issuedCertificatePEM: "i",
            issuedFingerprint: "f",
            agentPort: 7_778,
            jwtSecret: "issuer-new-secret",
            adminUser: PairingAdminUser(
                id: "home-admin",
                username: "other",
                passwordHash: "hashed:issuer",
            ),
        )
        await #expect(throws: PairingError.self) {
            try await PairingService.applySharedIdentity(
                response,
                dataDir: dir,
                now: Date(timeIntervalSince1970: 1_700_000_000),
                db: db,
                keys: nil,
            )
        }

        #expect(Config.loadJWTSecret(from: dir) == "joiner-old-secret")
        let users = try await db.read { db in try User.fetchAll(db) }
        #expect(users.count == 1)
        #expect(users[0].id == "home-admin")
        #expect(users[0].username == "pascal")
        #expect(users[0].password == "hashed:local")
    }
}
