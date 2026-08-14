import Foundation
import GRDB
import JWTKit
import Testing
@testable import BarkVisorCore

private struct IdentityPasswordHasher: PasswordHasher {
    func hash(_ password: String) throws -> String {
        "hashed:\(password)"
    }

    func verify(_ password: String, against hash: String) throws -> Bool {
        hash == "hashed:\(password)"
    }
}

@Suite("Shared identity (PAS-81)")
struct PairingIdentityTests {
    private let hasher = IdentityPasswordHasher()

    private func isolatedDir(_ label: String = "id") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isolatedPool(_ dir: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }

    private struct PairFixture {
        var issuerDir: URL
        var joinerDir: URL
        var issuerId: String
        var joinerId: String
        var issuer: HomeCertificateMaterial
        var joiner: HomeCertificateMaterial
        var payload: PairingPayload
    }

    private func pairMaterial() throws -> PairFixture {
        let issuerDir = try isolatedDir("iss")
        let joinerDir = try isolatedDir("join")
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.168.0.9",
            port: 7_777,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        return PairFixture(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
            issuer: issuer,
            joiner: joiner,
            payload: payload,
        )
    }

    @Test func `redeem attaches jwt secret and admin hash not password`() throws {
        let issuerDir = try isolatedDir("iss-redeem")
        let joinerDir = try isolatedDir("join-redeem")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let admin = PairingAdminIdentity(
            id: "admin-1",
            username: "house",
            passwordHash: "hashed:home-password",
        )
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: issued.code,
                    hostId: joiner.hostId,
                    csrPEM: HomeCAService.makeDeviceCSR(
                        hostId: joiner.hostId,
                        keyPEM: joiner.deviceKeyPEM,
                    ),
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                ),
                jwtSecret: "issuer-home-jwt",
                admin: admin,
            ),
            offers: offers,
        )
        #expect(remote.jwtSecret == "issuer-home-jwt")
        #expect(remote.admin == admin)
        let encoded = try JSONEncoder().encode(remote)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["jwtSecret"] as? String == "issuer-home-jwt")
        let adminJSON = try #require(object["admin"] as? [String: Any])
        #expect(adminJSON["id"] as? String == "admin-1")
        #expect(adminJSON["username"] as? String == "house")
        #expect(adminJSON["passwordHash"] as? String == "hashed:home-password")
        #expect(adminJSON["password"] == nil)
        #expect(String(data: encoded, encoding: .utf8)?.contains("home-password") == true)
        #expect(String(data: encoded, encoding: .utf8)?.contains("\"password\"") == false)
        #expect(!FileManager.default.fileExists(atPath: issuerDir.appendingPathComponent("db.sqlite").path))
    }

    @Test func `redeem without identity fails before consuming the code`() throws {
        let issuerDir = try isolatedDir("iss-empty")
        let joinerDir = try isolatedDir("join-empty")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        #expect(throws: PairingError.self) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: issuerDir,
                    issuerHostId: issuerId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: joiner.hostId,
                        csrPEM: HomeCAService.makeDeviceCSR(
                            hostId: joiner.hostId,
                            keyPEM: joiner.deviceKeyPEM,
                        ),
                        deviceCertificatePEM: joiner.deviceCertificatePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                    jwtSecret: "",
                    admin: PairingAdminIdentity(id: "", username: "", passwordHash: ""),
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
    }

    @Test func `applyTrust replaces jwt secret and upserts admin for local login`() async throws {
        let pair = try pairMaterial()
        defer {
            try? FileManager.default.removeItem(at: pair.issuerDir)
            try? FileManager.default.removeItem(at: pair.joinerDir)
        }
        try Data("old-local-secret".utf8).write(to: JWTSecret.fileURL(in: pair.joinerDir))
        let pool = try isolatedPool(pair.joinerDir)
        try await pool.write { db in
            try User(
                id: "local-admin",
                username: "admin",
                password: "hashed:old-password",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }

        var remote = try honestRedeem(
            issuer: pair.issuer,
            issuerId: pair.issuerId,
            joiner: pair.joiner,
            joinerId: pair.joinerId,
        )
        remote.jwtSecret = "issuer-home-jwt"
        remote.admin = PairingAdminIdentity(
            id: "home-admin",
            username: "admin",
            passwordHash: "hashed:home-password",
        )

        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "old-local-secret"), digestAlgorithm: .sha256)
        _ = try PairingService.applyTrust(
            response: remote,
            expected: pair.payload,
            dataDir: pair.joinerDir,
            localHostId: pair.joinerId,
            db: pool,
        )
        await JWTSecret.reloadHMAC(keys, secret: remote.jwtSecret)

        #expect(JWTSecret.load(dataDir: pair.joinerDir) == "issuer-home-jwt")
        let attrs = try FileManager.default.attributesOfItem(
            atPath: JWTSecret.fileURL(in: pair.joinerDir).path,
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)

        let users = try await pool.read { try User.fetchAll($0) }
        #expect(users.count == 1)
        #expect(users[0].id == "home-admin")
        #expect(users[0].username == "admin")
        #expect(users[0].password == "hashed:home-password")

        let (token, user) = try await AuthService.login(
            username: "admin",
            password: "home-password",
            hasher: hasher,
            keys: keys,
            db: pool,
        )
        #expect(user.id == "home-admin")
        #expect(!token.isEmpty)
        let payload = try await keys.verify(token, as: UserPayload.self)
        #expect(payload.username == "admin")
        #expect(payload.sub.value == "home-admin")
    }

    @Test func `reloaded hmac signs with new secret without restart`() async throws {
        let dir = try isolatedDir("hmac")
        defer { try? FileManager.default.removeItem(at: dir) }
        try JWTSecret.replace("old-secret", dataDir: dir)
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "old-secret"), digestAlgorithm: .sha256)
        let oldPayload = UserPayload(
            sub: .init(value: "u1"),
            username: "admin",
            exp: .init(value: Date().addingTimeInterval(60)),
        )
        let oldToken = try await keys.sign(oldPayload)

        try JWTSecret.replace("new-secret", dataDir: dir)
        await JWTSecret.reloadHMAC(keys, secret: "new-secret")
        let newToken = try await keys.sign(oldPayload)
        let verified = try await keys.verify(newToken, as: UserPayload.self)
        #expect(verified.username == "admin")
        await #expect(throws: (any Error).self) {
            try await keys.verify(oldToken, as: UserPayload.self)
        }
        #expect(JWTSecret.load(dataDir: dir) == "new-secret")
    }

    @Test func `applyTrust writes jwt secret without opening sqlite`() throws {
        let pair = try pairMaterial()
        defer {
            try? FileManager.default.removeItem(at: pair.issuerDir)
            try? FileManager.default.removeItem(at: pair.joinerDir)
        }
        let remote = try honestRedeem(
            issuer: pair.issuer,
            issuerId: pair.issuerId,
            joiner: pair.joiner,
            joinerId: pair.joinerId,
        )
        _ = try PairingService.applyTrust(
            response: remote,
            expected: pair.payload,
            dataDir: pair.joinerDir,
            localHostId: pair.joinerId,
        )
        #expect(JWTSecret.load(dataDir: pair.joinerDir) == "issuer-home-jwt")
        #expect(
            !FileManager.default.fileExists(
                atPath: pair.joinerDir.appendingPathComponent("db.sqlite").path,
            ),
        )
    }

    @Test func `applyTrust keeps a distinct local user and still logs in offline`() async throws {
        let pair = try pairMaterial()
        defer {
            try? FileManager.default.removeItem(at: pair.issuerDir)
            try? FileManager.default.removeItem(at: pair.joinerDir)
        }
        let pool = try isolatedPool(pair.joinerDir)
        try await pool.write { db in
            try User(
                id: "break-glass",
                username: "local",
                password: "hashed:local-password",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }
        var remote = try honestRedeem(
            issuer: pair.issuer,
            issuerId: pair.issuerId,
            joiner: pair.joiner,
            joinerId: pair.joinerId,
        )
        remote.admin = PairingAdminIdentity(
            id: "home-admin",
            username: "admin",
            passwordHash: "hashed:home-password",
        )
        _ = try PairingService.applyTrust(
            response: remote,
            expected: pair.payload,
            dataDir: pair.joinerDir,
            localHostId: pair.joinerId,
            db: pool,
        )
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: remote.jwtSecret), digestAlgorithm: .sha256)
        let home = try await AuthService.login(
            username: "admin",
            password: "home-password",
            hasher: hasher,
            keys: keys,
            db: pool,
        )
        let local = try await AuthService.login(
            username: "local",
            password: "local-password",
            hasher: hasher,
            keys: keys,
            db: pool,
        )
        #expect(home.user.id == "home-admin")
        #expect(local.user.id == "break-glass")
    }

    @Test func `applyTrust rejects incomplete identity after cert checks`() throws {
        let pair = try pairMaterial()
        defer {
            try? FileManager.default.removeItem(at: pair.issuerDir)
            try? FileManager.default.removeItem(at: pair.joinerDir)
        }
        var remote = try honestRedeem(
            issuer: pair.issuer,
            issuerId: pair.issuerId,
            joiner: pair.joiner,
            joinerId: pair.joinerId,
        )
        remote.jwtSecret = ""
        #expect(throws: PairingError.self) {
            try PairingService.applyTrust(
                response: remote,
                expected: pair.payload,
                dataDir: pair.joinerDir,
                localHostId: pair.joinerId,
            )
        }
        #expect(JWTSecret.load(dataDir: pair.joinerDir) == nil)
        #expect(try PairingService.loadReceipt(dataDir: pair.joinerDir) == nil)
    }

    private func honestRedeem(
        issuer: HomeCertificateMaterial,
        issuerId: String,
        joiner: HomeCertificateMaterial,
        joinerId: String,
    ) throws -> PairingRedeemResponse {
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: joinerId,
            csrPEM: csr,
            material: issuer,
        )
        return PairingRedeemResponse(
            hostId: issuerId,
            deviceCertificatePEM: issuer.deviceCertificatePEM,
            deviceFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            agentPort: 7_778,
            jwtSecret: "issuer-home-jwt",
            admin: PairingAdminIdentity(
                id: "home-admin",
                username: "admin",
                passwordHash: "hashed:home-password",
            ),
        )
    }
}
