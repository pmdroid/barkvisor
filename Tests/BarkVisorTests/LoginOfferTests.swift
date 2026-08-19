import Foundation
import GRDB
import JWTKit
import Testing
@testable import BarkVisorCore

struct LoginOfferTests {
    private func makeDB() throws -> (URL, DatabasePool) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPool = try DatabasePool(path: tmpDir.appendingPathComponent("test.sqlite").path)
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

    @Test func `mint uses advertised host allow-list`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
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
        #expect(offer.host == "192.168.0.8")
        #expect(offer.port == 7_777)
        #expect(offer.uri.hasPrefix("barkvisor://login/v1?"))
        #expect(!offer.uri.contains("pair/v1"))
        #expect(PairingCode.isValid(offer.code))
        let parsed = try LoginPayload.parse(offer.uri)
        #expect(parsed.host == "192.168.0.8")
        #expect(parsed.port == 7_777)
    }

    @Test func `mint rejects a public advertised host`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        await #expect(throws: BarkVisorError.self) {
            try await LoginOfferService.issue(
                LoginOfferService.IssueInput(
                    userId: "user-1",
                    advertisedHost: "8.8.8.8",
                    advertisedHosts: [],
                    port: 7_777,
                ),
                db: db,
            )
        }
    }

    @Test func `mint rejects invalid advertised host instead of falling back`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await LoginOfferService.issue(
                LoginOfferService.IssueInput(
                    userId: "user-1",
                    advertisedHost: "8.8.8.8",
                    advertisedHosts: ["192.168.0.8"],
                    port: 7_777,
                ),
                db: db,
            )
            Issue.record("expected invalid advertisedHost to reject")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.contains("Invalid advertised host"))
        }
        await #expect(throws: BarkVisorError.self) {
            try await LoginOfferService.issue(
                LoginOfferService.IssueInput(
                    userId: "user-1",
                    advertisedHost: "localhost",
                    advertisedHosts: ["192.168.0.8"],
                ),
                db: db,
            )
        }
    }

    @Test func `mint accepts single-label and ULA advertised hosts`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let named = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "nas",
                advertisedHosts: ["192.168.0.8"],
            ),
            db: db,
        )
        #expect(named.host == "nas")
        let ula = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "fd12:3456:789a::1",
                advertisedHosts: ["192.168.0.8"],
            ),
            db: db,
        )
        #expect(ula.host == "fd12:3456:789a::1")
    }

    @Test func `only one active offer`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let first = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            db: db,
        )
        let second = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "10.0.0.4",
                advertisedHosts: ["10.0.0.4"],
            ),
            db: db,
        )
        #expect(first.code != second.code)
        let count = try await db.read { db in try LoginOfferRecord.fetchCount(db) }
        #expect(count == 1)
        let current = try await LoginOfferService.current(db: db)
        #expect(current.code == second.code)
    }

    @Test func `redeem returns jwt and refresh token`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date()
        let offer = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                now: now,
            ),
            db: db,
        )
        let session = try await LoginOfferService.redeem(
            code: offer.code, keys: keys, db: db, now: now.addingTimeInterval(30),
        )
        #expect(session.user.id == "user-1")
        #expect(session.refreshToken.hasPrefix("bvrt_"))
        _ = try await keys.verify(session.token, as: UserPayload.self)
        await #expect(throws: BarkVisorError.self) {
            try await LoginOfferService.redeem(
                code: offer.code, keys: keys, db: db, now: now.addingTimeInterval(40),
            )
        }
    }

    @Test func `failed jwt issuance leaves the offer redeemable`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let emptyKeys = JWTKeyCollection()
        let now = Date()
        let offer = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                now: now,
            ),
            db: db,
        )
        await #expect(throws: Error.self) {
            try await LoginOfferService.redeem(
                code: offer.code, keys: emptyKeys, db: db, now: now.addingTimeInterval(30),
            )
        }
        let current = try await LoginOfferService.current(now: now.addingTimeInterval(31), db: db)
        #expect(current.code == offer.code)
        let rows = try await db.read { db in try RefreshTokenRecord.fetchCount(db) }
        #expect(rows == 0)
    }

    @Test func `expired offer cannot be redeemed`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let offer = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: "user-1",
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                ttl: 180,
                now: now,
            ),
            db: db,
        )
        await #expect(throws: BarkVisorError.self) {
            try await LoginOfferService.redeem(
                code: offer.code, keys: keys, db: db, now: now.addingTimeInterval(181),
            )
        }
    }

    @Test func `login uri is not a pairing uri`() throws {
        let login = LoginPayload(code: "ABCD-EFGH", host: "192.168.0.8", port: 7_777)
        #expect(login.uri.contains("barkvisor://login/v1"))
        #expect(!login.uri.contains("barkvisor://pair/v1"))
        #expect(throws: BarkVisorError.self) {
            try LoginPayload.parse(
                "barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&hostId=h&fp=abc",
            )
        }
        let parsed = try LoginPayload.parse("  \(login.uri)  ")
        #expect(parsed.code == "ABCD-EFGH")
        #expect(parsed.host == "192.168.0.8")
        #expect(parsed.port == 7_777)
        let named = try LoginPayload.parse("barkvisor://login/v1?code=ABCD-EFGH&host=nas&port=7777")
        #expect(named.host == "nas")
        let ula = try LoginPayload.parse(
            "barkvisor://login/v1?code=ABCD-EFGH&host=fd12:3456:789a::1&port=7777",
        )
        #expect(ula.host == "fd12:3456:789a::1")
    }
}
