import Foundation
import JWTKit
import Testing
@testable import BarkVisorCore

@Suite("Legacy Home member credentials")
struct LegacyHomeHopTests {
    private struct Fixture {
        let dir: URL
        let home: HomeCertificateMaterial
        let localHostId = UUID().uuidString
        let secret = UUID().uuidString

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            home = try HomeCAService.loadOrCreate(
                dataDir: dir.appendingPathComponent("home"), hostId: UUID().uuidString,
            )
            try Config.persistJWTSecret(secret, to: dir)
            try PairingService.persistReceipt(
                PairingPeerReceipt(
                    peerHostId: home.hostId,
                    peerFingerprint: home.deviceFingerprint,
                    caCertificatePEM: home.caCertificatePEM,
                    caFingerprint: home.caFingerprint,
                    issuedCertificatePEM: home.deviceCertificatePEM,
                    issuedFingerprint: home.deviceFingerprint,
                    pairedAt: iso8601.string(from: Date()),
                ),
                dataDir: dir,
            )
            try PeerPinStore(dataDir: dir).pin(
                hostId: home.hostId, fingerprint: home.deviceFingerprint,
            )
        }

        func token(secret: String? = nil, ttl: TimeInterval = 120, role: String = "admin") async throws -> String {
            let keys = JWTKeyCollection()
            await keys.add(hmac: .init(from: secret ?? self.secret), digestAlgorithm: .sha256)
            return try await AuthService.signMemberHopToken(
                userId: "paired-admin", username: "admin", role: role, keys: keys, ttl: ttl,
            )
        }

        func translate(_ token: String, peerHostId: String? = nil, certificate: String? = nil) async throws -> String {
            try await HomeMemberHop.localLegacyToken(
                dataDir: dir,
                localHostId: localHostId,
                peerHostId: peerHostId ?? home.hostId,
                peerCertificatePEM: certificate ?? home.deviceCertificatePEM,
                token: token,
            )
        }
    }

    @Test func `migration preserves paired legacy verification while rotating local signing`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let token = try await fixture.token(role: "inference")
        try HomeMembershipAuthority.migrateExistingHome(
            dataDir: fixture.dir, localHostId: fixture.localHostId,
        )
        let localSecret = try #require(Config.loadJWTSecret(from: fixture.dir))
        #expect(localSecret != fixture.secret)
        #expect(try PairingService.loadReceipt(dataDir: fixture.dir)?.legacyJWTSecret == fixture.secret)
        let translated = try await fixture.translate(token)
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: localSecret), digestAlgorithm: .sha256)
        let payload = try await keys.verify(translated, as: UserPayload.self)
        #expect(payload.sub.value == "paired-admin")
        #expect(payload.role == "inference")
        await #expect(throws: Error.self) { try await keys.verify(token, as: UserPayload.self) }
        let receipt = try Data(contentsOf: PairingService.receiptURL(in: fixture.dir))
        try HomeMembershipAuthority.migrateExistingHome(
            dataDir: fixture.dir, localHostId: fixture.localHostId,
        )
        _ = try await fixture.translate(token)
        #expect(try Data(contentsOf: PairingService.receiptURL(in: fixture.dir)) == receipt)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: PairingService.receiptURL(in: fixture.dir).path,
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func `already migrated join recovers the imported key without re-pairing`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        try HomeMembershipAuthority.migrateExistingHome(
            dataDir: fixture.dir, localHostId: fixture.localHostId,
        )
        var receipt = try #require(try PairingService.loadReceipt(dataDir: fixture.dir))
        receipt.legacyJWTSecret = nil
        try PairingService.persistReceipt(receipt, dataDir: fixture.dir)
        try Config.persistJWTSecret(fixture.secret, to: fixture.dir)
        _ = try await fixture.translate(fixture.token())
        #expect(try PairingService.loadReceipt(dataDir: fixture.dir)?.legacyJWTSecret == fixture.secret)
    }

    @Test(arguments: [-30.0, 3_600.0])
    func `expired and long-lived credentials are rejected`(ttl: TimeInterval) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let token = try await fixture.token(ttl: ttl)
        await #expect(throws: BarkVisorError.self) { try await fixture.translate(token) }
    }

    @Test func `wrong signer host or certificate cannot use the legacy path`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let token = try await fixture.token()
        let wrongKeyToken = try await fixture.token(secret: "wrong-secret")
        await #expect(throws: BarkVisorError.self) { try await fixture.translate(wrongKeyToken) }
        await #expect(throws: BarkVisorError.self) {
            try await fixture.translate(token, peerHostId: "another-home")
        }
        let other = try HomeCAService.loadOrCreate(
            dataDir: fixture.dir.appendingPathComponent("other"), hostId: fixture.home.hostId,
        )
        await #expect(throws: BarkVisorError.self) {
            try await fixture.translate(token, certificate: other.deviceCertificatePEM)
        }
        try FileManager.default.removeItem(at: PairingService.receiptURL(in: fixture.dir))
        await #expect(throws: BarkVisorError.self) { try await fixture.translate(token) }
    }

    @Test func `live legacy Home works beyond snapshot age but removal still revokes it`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        try HomeMembershipAuthority.migrateExistingHome(
            dataDir: fixture.dir, localHostId: fixture.localHostId,
            now: Date().addingTimeInterval(-2 * HomeMembershipPolicy.maximumStaleAuthorizationWindow),
        )
        let token = try await fixture.token()
        _ = try await fixture.translate(token)
        try HomeMembershipAuthority(dataDir: fixture.dir).removeMember(
            hostId: fixture.home.hostId, localHostId: fixture.localHostId,
        )
        await #expect(throws: BarkVisorError.self) { try await fixture.translate(token) }
    }
}
