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

struct TOTPTests {
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

    @Test func `rfc 6238 sha1 vectors`() {
        let secret = Data("12345678901234567890".utf8)
        #expect(Base32.encode(secret) == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        #expect(Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") == secret)

        let samples: [(TimeInterval, String)] = [
            (59, "94287082"),
            (1_111_111_109, "07081804"),
            (1_111_111_111, "14050471"),
            (1_234_567_890, "89005924"),
            (2_000_000_000, "69279037"),
            (20_000_000_000, "65353130"),
        ]
        for (unix, eight) in samples {
            let date = Date(timeIntervalSince1970: unix)
            #expect(TOTP.generate(secret: secret, at: date, digits: 8) == eight)
            #expect(TOTP.generate(secret: secret, at: date, digits: 6) == String(eight.suffix(6)))
        }
    }

    @Test func `password login without totp still issues a session`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let result = try await AuthService.passwordLogin(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
        )
        guard case let .session(session) = result else {
            Issue.record("expected session")
            return
        }
        #expect(session.refreshToken.hasPrefix("bvrt_"))
    }

    @Test func `setup confirm login challenge and recovery code`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = TOTP.generateSecret(bytes: Array(repeating: 7, count: 20))
        let setup = try await TOTPService.beginSetup(
            userId: "user-1", username: "admin", db: db, now: now, secret: secret,
        )
        #expect(setup.otpauthUrl.contains("otpauth://totp/"))
        #expect(setup.otpauthUrl.contains("issuer=BarkVisor"))
        #expect(setup.account == "admin")

        let secretData = try #require(Base32.decode(secret))
        let code = TOTP.generate(secret: secretData, at: now)
        let recovery = try await TOTPService.confirmSetup(userId: "user-1", code: code, db: db, now: now)
        #expect(recovery.recoveryCodes.count == 10)
        #expect(try await TOTPService.isEnabled(userId: "user-1", db: db))

        let result = try await AuthService.passwordLogin(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: now.addingTimeInterval(30),
        )
        guard case let .totpChallenge(challenge) = result else {
            Issue.record("expected TOTP challenge")
            return
        }
        #expect(challenge.challengeToken.hasPrefix("bvch_"))

        let later = now.addingTimeInterval(30)
        let nextCode = TOTP.generate(secret: secretData, at: later)
        let session = try await AuthService.completeLoginChallenge(
            challengeToken: challenge.challengeToken,
            code: nextCode,
            keys: keys,
            db: db,
            now: later,
        )
        #expect(session.user.username == "admin")
        #expect(session.refreshToken.hasPrefix("bvrt_"))

        await #expect(throws: BarkVisorError.self) {
            try await AuthService.completeLoginChallenge(
                challengeToken: challenge.challengeToken,
                code: nextCode,
                keys: keys,
                db: db,
                now: later,
            )
        }

        let again = try await AuthService.passwordLogin(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: later.addingTimeInterval(30),
        )
        guard case let .totpChallenge(second) = again else {
            Issue.record("expected second challenge")
            return
        }
        let recovered = try await AuthService.completeLoginChallenge(
            challengeToken: second.challengeToken,
            code: recovery.recoveryCodes[0],
            keys: keys,
            db: db,
            now: later.addingTimeInterval(30),
        )
        #expect(recovered.user.username == "admin")

        let third = try await AuthService.passwordLogin(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: later.addingTimeInterval(60),
        )
        guard case let .totpChallenge(reuse) = third else {
            Issue.record("expected challenge after used recovery code")
            return
        }
        await #expect(throws: BarkVisorError.self) {
            try await AuthService.completeLoginChallenge(
                challengeToken: reuse.challengeToken,
                code: recovery.recoveryCodes[0],
                keys: keys,
                db: db,
                now: later.addingTimeInterval(60),
            )
        }
    }

    @Test func `replayed totp is rejected`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = Date(timeIntervalSince1970: 1_700_000_030)
        let secret = TOTP.generateSecret(bytes: Array(repeating: 9, count: 20))
        _ = try await TOTPService.beginSetup(
            userId: "user-1", username: "admin", db: db, now: now, secret: secret,
        )
        let secretData = try #require(Base32.decode(secret))
        let code = TOTP.generate(secret: secretData, at: now)
        _ = try await TOTPService.confirmSetup(userId: "user-1", code: code, db: db, now: now)

        await #expect(throws: BarkVisorError.self) {
            try await TOTPService.consumeLoginChallenge(
                token: "unused",
                code: code,
                db: db,
                now: now,
            )
        }

        let challenge = try await TOTPService.issueLoginChallenge(userId: "user-1", db: db, now: now)
        await #expect(throws: BarkVisorError.self) {
            try await TOTPService.consumeLoginChallenge(
                token: challenge.challengeToken,
                code: code,
                db: db,
                now: now,
            )
        }
    }

    @Test func `login offer redeem still works when totp is enabled`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = TOTP.generateSecret(bytes: Array(repeating: 3, count: 20))
        _ = try await TOTPService.beginSetup(
            userId: "user-1", username: "admin", db: db, now: now, secret: secret,
        )
        let secretData = try #require(Base32.decode(secret))
        let code = TOTP.generate(secret: secretData, at: now)
        _ = try await TOTPService.confirmSetup(userId: "user-1", code: code, db: db, now: now)

        let offer = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                port: 7_777,
                now: now,
            ),
            db: db,
        )
        let session = try await LoginOfferService.redeem(code: offer.code, keys: keys, db: db, now: now)
        #expect(session.user.username == "admin")
        #expect(session.refreshToken.hasPrefix("bvrt_"))
    }

    @Test func `disable requires a valid second factor`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = TOTP.generateSecret(bytes: Array(repeating: 1, count: 20))
        _ = try await TOTPService.beginSetup(
            userId: "user-1", username: "admin", db: db, now: now, secret: secret,
        )
        let secretData = try #require(Base32.decode(secret))
        let enableCode = TOTP.generate(secret: secretData, at: now)
        _ = try await TOTPService.confirmSetup(userId: "user-1", code: enableCode, db: db, now: now)

        await #expect(throws: BarkVisorError.self) {
            try await TOTPService.disable(userId: "user-1", code: "000000", db: db, now: now)
        }
        #expect(try await TOTPService.isEnabled(userId: "user-1", db: db))

        let later = now.addingTimeInterval(30)
        let disableCode = TOTP.generate(secret: secretData, at: later)
        try await TOTPService.disable(userId: "user-1", code: disableCode, db: db, now: later)
        #expect(try await TOTPService.isEnabled(userId: "user-1", db: db) == false)

        let keys = await makeKeys()
        let result = try await AuthService.passwordLogin(
            username: "admin",
            password: "testpass10",
            hasher: TestPasswordHasher(),
            keys: keys,
            db: db,
            now: later,
        )
        guard case .session = result else {
            Issue.record("expected session after disable")
            return
        }
    }
}
