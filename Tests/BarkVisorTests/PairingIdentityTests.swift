import Foundation
import GRDB
import JWTKit
import Testing
@testable import BarkVisorCore

@Suite("Pairing shared identity (PAS-81)")
struct PairingIdentityTests {
    private struct TestHasher: PasswordHasher {
        func hash(_ password: String) throws -> String {
            "hashed:\(password)"
        }
        func verify(_ password: String, against hash: String) throws -> Bool {
            hash == "hashed:\(password)"
        }
    }

    private func isolatedDir(_ label: String = "id") throws -> URL {
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

    private func insertAdmin(
        _ db: DatabasePool,
        id: String = "admin-1",
        username: String = "admin",
        password: String = "secretpass1",
    ) throws -> PairingAdminUser {
        let hash = try TestHasher().hash(password)
        try db.write { db in
            try User(
                id: id,
                username: username,
                password: hash,
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        return PairingAdminUser(id: id, username: username, passwordHash: hash)
    }

    @Test func `redeem attaches jwt secret and admin hash not plaintext`() throws {
        let issuerDir = try isolatedDir("iss")
        let joinerDir = try isolatedDir("join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        try Config.persistJWTSecret("issuer-hmac-secret", to: issuerDir)
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
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
        let admin = PairingAdminUser(
            id: "user-home",
            username: "pascal",
            passwordHash: "$2b$12$storedhashnotplaintextxxxx",
        )
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: issued.code,
                    hostId: joinerId,
                    csrPEM: HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM),
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                ),
                jwtSecret: "issuer-hmac-secret",
                adminUser: admin,
            ),
            offers: offers,
        )
        #expect(remote.jwtSecret == "issuer-hmac-secret")
        #expect(remote.adminUser == admin)
        let encoded = try JSONEncoder().encode(remote)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("passwordHash"))
        #expect(!json.contains("home-password"))
        #expect(!json.contains("\"password\""))
    }

    @Test func `redeem loads jwt secret from issuer data dir`() throws {
        let issuerDir = try isolatedDir("iss-file")
        let joinerDir = try isolatedDir("join-file")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        try Config.persistJWTSecret("from-disk-secret", to: issuerDir)
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(
            dataDir: joinerDir,
            hostId: UUID().uuidString,
        )
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
            ),
            offers: offers,
        )
        #expect(remote.jwtSecret == "from-disk-secret")
        #expect(remote.adminUser == nil)
    }

    @Test func `applyTrust replaces jwt secret upserts admin and reloads hmac`() async throws {
        let issuerDir = try isolatedDir("iss-apply")
        let joinerDir = try isolatedDir("join-apply")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let joinerDB = try makeDB(joinerDir)
        _ = try insertAdmin(joinerDB, id: "local-admin", username: "local", password: "oldpass1234")
        try Config.persistJWTSecret("joiner-old-secret", to: joinerDir)

        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "joiner-old-secret"), digestAlgorithm: .sha256)
        let stale = try await keys.sign(
            UserPayload(
                sub: .init(value: "local-admin"),
                username: "local",
                exp: .init(value: Date().addingTimeInterval(3_600)),
            ),
        )

        var remote = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        remote.jwtSecret = "issuer-new-secret"
        remote.adminUser = try PairingAdminUser(
            id: "home-admin",
            username: "pascal",
            passwordHash: TestHasher().hash("sharedpass1"),
        )
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.168.0.9",
            port: 7_777,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        _ = try await PairingService.applyTrust(
            response: remote,
            expected: payload,
            dataDir: joinerDir,
            localHostId: joinerId,
            db: joinerDB,
            keys: keys,
        )

        #expect(Config.loadJWTSecret(from: joinerDir) == "issuer-new-secret")
        let attrs = try FileManager.default.attributesOfItem(
            atPath: Config.jwtSecretFile(in: joinerDir).path,
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)

        let users = try await joinerDB.read { db in try User.fetchAll(db) }
        #expect(users.contains { $0.username == "pascal" && $0.password == "hashed:sharedpass1" })

        await #expect(throws: Error.self) {
            try await keys.verify(stale, as: UserPayload.self)
        }

        let (token, user) = try await AuthService.login(
            username: "pascal",
            password: "sharedpass1",
            hasher: TestHasher(),
            keys: keys,
            db: joinerDB,
        )
        #expect(user.username == "pascal")
        let verified = try await keys.verify(token, as: UserPayload.self)
        #expect(verified.username == "pascal")
    }

    @Test func `offline login works after pair without contacting peers`() async throws {
        let issuerDir = try isolatedDir("iss-off")
        let joinerDir = try isolatedDir("join-off")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let joinerDB = try makeDB(joinerDir)
        var remote = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        remote.jwtSecret = "offline-secret"
        remote.adminUser = try PairingAdminUser(
            id: "home-admin",
            username: "admin",
            passwordHash: TestHasher().hash("offlinepass"),
        )
        _ = try await PairingService.applyTrust(
            response: remote,
            expected: PairingPayload(
                code: "ABCD-EFGH",
                host: "192.168.0.9",
                port: 7_777,
                hostId: issuerId,
                fingerprint: issuer.deviceFingerprint,
            ),
            dataDir: joinerDir,
            localHostId: joinerId,
            db: joinerDB,
        )
        let keys = JWTKeyCollection()
        try await keys.add(
            hmac: .init(from: #require(Config.loadJWTSecret(from: joinerDir))),
            digestAlgorithm: .sha256,
        )
        let (token, user) = try await AuthService.login(
            username: "admin",
            password: "offlinepass",
            hasher: TestHasher(),
            keys: keys,
            db: joinerDB,
        )
        #expect(user.username == "admin")
        #expect(!token.isEmpty)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: issuer.deviceFingerprint))
    }

    @Test func `applyTrust with admin identity requires a local database`() async throws {
        let issuerDir = try isolatedDir("iss-nodb")
        let joinerDir = try isolatedDir("join-nodb")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        try Config.persistJWTSecret("keep-local", to: joinerDir)
        var remote = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        remote.jwtSecret = "should-not-replace"
        remote.adminUser = PairingAdminUser(
            id: "home-admin",
            username: "admin",
            passwordHash: "hashed:x",
        )
        await #expect(throws: PairingError.self) {
            try await PairingService.applyTrust(
                response: remote,
                expected: PairingPayload(
                    code: "ABCD-EFGH",
                    host: "192.168.0.9",
                    port: 7_777,
                    hostId: issuerId,
                    fingerprint: issuer.deviceFingerprint,
                ),
                dataDir: joinerDir,
                localHostId: joinerId,
            )
        }
        #expect(Config.loadJWTSecret(from: joinerDir) == "keep-local")
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.peerHostId == issuerId)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: issuer.deviceFingerprint))
    }

    @Test func `receipt persist failure leaves local jwt and admin unchanged`() async throws {
        let issuerDir = try isolatedDir("iss-receipt-auth")
        let joinerDir = try isolatedDir("join-receipt-auth")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let joinerDB = try makeDB(joinerDir)
        _ = try insertAdmin(joinerDB, id: "local-admin", username: "local", password: "oldpass1234")
        try Config.persistJWTSecret("keep-local", to: joinerDir)

        var remote = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        remote.jwtSecret = "should-not-replace"
        remote.adminUser = PairingAdminUser(
            id: "home-admin",
            username: "admin",
            passwordHash: "hashed:shared",
        )
        let receiptURL = PairingService.receiptURL(in: joinerDir)
        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
        await #expect(throws: PairingError.self) {
            try await PairingService.applyTrust(
                response: remote,
                expected: PairingPayload(
                    code: "ABCD-EFGH",
                    host: "192.168.0.9",
                    port: 7_777,
                    hostId: issuerId,
                    fingerprint: issuer.deviceFingerprint,
                ),
                dataDir: joinerDir,
                localHostId: joinerId,
                db: joinerDB,
            )
        }
        #expect(Config.loadJWTSecret(from: joinerDir) == "keep-local")
        let users = try await joinerDB.read { db in try User.fetchAll(db) }
        #expect(users.count == 1)
        #expect(users[0].id == "local-admin")
        #expect(users[0].username == "local")
        #expect(users[0].password == "hashed:oldpass1234")
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
    }

    @Test func `jwt secret persist failure leaves local admin unchanged`() async throws {
        let issuerDir = try isolatedDir("iss-secret-fail")
        let joinerDir = try isolatedDir("join-secret-fail")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let joinerDB = try makeDB(joinerDir)
        _ = try insertAdmin(joinerDB, id: "local-admin", username: "local", password: "oldpass1234")

        var remote = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        remote.jwtSecret = "should-not-replace"
        remote.adminUser = PairingAdminUser(
            id: "home-admin",
            username: "admin",
            passwordHash: "hashed:shared",
        )
        try FileManager.default.createDirectory(
            at: Config.jwtSecretFile(in: joinerDir),
            withIntermediateDirectories: true,
        )
        await #expect(throws: PairingError.self) {
            try await PairingService.applyTrust(
                response: remote,
                expected: PairingPayload(
                    code: "ABCD-EFGH",
                    host: "192.168.0.9",
                    port: 7_777,
                    hostId: issuerId,
                    fingerprint: issuer.deviceFingerprint,
                ),
                dataDir: joinerDir,
                localHostId: joinerId,
                db: joinerDB,
            )
        }
        #expect(Config.loadJWTSecret(from: joinerDir) == nil)
        let users = try await joinerDB.read { db in try User.fetchAll(db) }
        #expect(users.count == 1)
        #expect(users[0].id == "local-admin")
        #expect(users[0].username == "local")
        #expect(users[0].password == "hashed:oldpass1234")
    }

    @Test func `loadAdminUser returns earliest password-backed user`() throws {
        let dir = try isolatedDir("admin-order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeDB(dir)
        try db.write { db in
            try User(
                id: "later-admin",
                username: "second",
                password: "hashed:later",
                createdAt: "2026-02-01T00:00:00Z",
            ).insert(db)
            try User(
                id: "earliest-admin",
                username: "first",
                password: "hashed:first",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
            try User(
                id: "no-password",
                username: "setup",
                password: "",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }
        let admin = try PairingService.loadAdminUser(db: db)
        #expect(admin?.id == "earliest-admin")
        #expect(admin?.username == "first")
        #expect(admin?.passwordHash == "hashed:first")
    }

    @Test func `join copies identity through existing redeem`() async throws {
        let issuerDir = try isolatedDir("iss-join")
        let joinerDir = try isolatedDir("join-join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        try Config.persistJWTSecret("home-jwt", to: issuerDir)
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        _ = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let issuerDB = try makeDB(issuerDir)
        let joinerDB = try makeDB(joinerDir)
        let admin = try insertAdmin(
            issuerDB,
            id: "home-admin",
            username: "pascal",
            password: "sharedpass1",
        )
        let offers = PairingOfferStore(dataDir: issuerDir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.168.0.20",
                advertisedHosts: ["192.168.0.20"],
            ),
            offers: offers,
        )
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "joiner-local"), digestAlgorithm: .sha256)
        let client = IdentityRedeemClient { body in
            let request = try JSONDecoder().decode(PairingRedeemRequest.self, from: body)
            return try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: issuerDir,
                    issuerHostId: issuerId,
                    request: request,
                    jwtSecret: "home-jwt",
                    adminUser: admin,
                ),
                offers: offers,
            )
        }
        let result = try await PairingService.join(
            request: PairingJoinRequest(qrPayload: issued.qrPayload),
            dataDir: joinerDir,
            hostId: joinerId,
            client: client,
            db: joinerDB,
            keys: keys,
        )
        #expect(result.peerHostId == issuerId)
        #expect(Config.loadJWTSecret(from: joinerDir) == "home-jwt")
        let copied = try await joinerDB.read { db in
            try User.filter(User.Columns.username == "pascal").fetchOne(db)
        }
        #expect(copied?.password == admin.passwordHash)
        let (token, user) = try await AuthService.login(
            username: "pascal",
            password: "sharedpass1",
            hasher: TestHasher(),
            keys: keys,
            db: joinerDB,
        )
        #expect(user.username == "pascal")
        #expect(!token.isEmpty)
    }
}

private func honestRedeemResponse(
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
    )
}

private struct IdentityRedeemClient: PairingHTTPClient {
    let handler: @Sendable (Data) throws -> PairingRedeemResponse

    func get(url: URL) async throws -> PairingHTTPResponse {
        struct Probe: Encodable { var apiVersion: Int }
        return try PairingHTTPResponse(
            status: 200,
            body: JSONEncoder().encode(Probe(apiVersion: APIContract.version)),
        )
    }

    func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
        let response = try handler(body)
        return try PairingHTTPResponse(status: 200, body: JSONEncoder().encode(response))
    }
}
