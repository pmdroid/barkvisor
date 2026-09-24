import Crypto
import Foundation
import GRDB
import JWTKit
import Testing
import X509
@testable import BarkVisorCore

@Suite("Home membership authority")
struct HomeMembershipAuthorityTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "home-membership-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `removal blocks certificate login-token and proxy credentials`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authority = HomeMembershipAuthority(dataDir: dir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try authority.beginAdmission(
            exchangeId: "exchange-1",
            hostId: "peer",
            fingerprint: "aa",
            now: now,
        )
        try authority.commitAdmission(
            exchangeId: "exchange-1",
            hostId: "peer",
            fingerprint: "aa",
            now: now,
        )
        let devices = DeviceRegistry(dataDir: dir)
        let pins = PeerPinStore(dataDir: dir)
        try devices.upsert(hostId: "peer", fingerprint: "aa", agentHost: "192.168.1.9")
        try pins.pin(hostId: "peer", fingerprint: "aa", now: now)

        #expect(
            authority.authorizeCertificate(hostId: "peer", fingerprint: "aa", now: now) == .allow,
        )
        #expect(
            authority.authorizeProxy(
                callerHostId: "peer",
                targetHostId: "peer",
                fingerprint: "aa",
                localHostId: "self",
                now: now,
            ) == .allow,
        )
        #expect(
            authority.authorizeLoginToken(
                issuerHostId: "peer",
                subjectHostId: "peer",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(60),
                membershipRevision: 1,
                localHostId: "self",
                now: now,
            ) == .allow,
        )

        try HomeDeviceMembership.remove(
            hostId: "peer",
            localHostId: "self",
            dataDir: dir,
            devices: devices,
            pins: pins,
        )

        #expect(try devices.record(forHostId: "peer") == nil)
        #expect(try pins.pin(forHostId: "peer") == nil)
        #expect(
            authority.authorizeCertificate(hostId: "peer", fingerprint: "aa", now: now)
                == .deny("Removed member certificate"),
        )
        #expect(
            authority.authorizeLoginToken(
                issuerHostId: "peer",
                subjectHostId: "peer",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(60),
                membershipRevision: 99,
                localHostId: "self",
                now: now,
            ) == .deny("Removed member login token"),
        )
        #expect(
            authority.authorizeProxy(
                callerHostId: nil,
                targetHostId: "peer",
                fingerprint: "aa",
                localHostId: "self",
                now: now,
            ) == .deny("Removed member cannot be proxied"),
        )
    }

    @Test func `disconnected peers stop authorizing after the stale window`() throws {
        let issuerDir = try isolatedDir()
        let peerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: peerDir)
        }
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: "issuer")
        let peer = try HomeCAService.loadOrCreate(dataDir: peerDir, hostId: "peer")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let issuerAuthority = HomeMembershipAuthority(dataDir: issuerDir)
        let peerAuthority = HomeMembershipAuthority(dataDir: peerDir)
        try issuerAuthority.beginAdmission(
            exchangeId: "ex",
            hostId: "peer",
            fingerprint: peer.deviceFingerprint,
            now: started,
        )
        try issuerAuthority.commitAdmission(
            exchangeId: "ex",
            hostId: "peer",
            fingerprint: peer.deviceFingerprint,
            now: started,
        )
        try peerAuthority.beginAdmission(
            exchangeId: "ex",
            hostId: "issuer",
            fingerprint: issuer.deviceFingerprint,
            now: started,
        )
        try peerAuthority.commitAdmission(
            exchangeId: "ex",
            hostId: "issuer",
            fingerprint: issuer.deviceFingerprint,
            now: started,
        )

        let inside = started.addingTimeInterval(
            HomeMembershipPolicy.maximumStaleAuthorizationWindow - 1,
        )
        #expect(
            peerAuthority.authorizeCertificate(
                hostId: "issuer",
                fingerprint: issuer.deviceFingerprint,
                now: inside,
            ) == .allow,
        )

        try issuerAuthority.removeMember(hostId: "peer", localHostId: "issuer", now: inside)
        #expect(
            issuerAuthority.authorizeCertificate(
                hostId: "peer",
                fingerprint: peer.deviceFingerprint,
                now: inside,
            ) == .deny("Removed member certificate"),
        )
        #expect(
            peerAuthority.authorizeCertificate(
                hostId: "issuer",
                fingerprint: issuer.deviceFingerprint,
                now: inside,
            ) == .allow,
        )

        let snapshot = try issuerAuthority.signedSnapshot(
            signerHostId: "issuer",
            deviceCertificatePEM: issuer.deviceCertificatePEM,
            deviceKeyPEM: issuer.deviceKeyPEM,
            now: inside,
        )
        let stale = started.addingTimeInterval(
            HomeMembershipPolicy.maximumStaleAuthorizationWindow + 5,
        )
        #expect(
            peerAuthority.authorizeCertificate(
                hostId: "issuer",
                fingerprint: issuer.deviceFingerprint,
                now: stale,
            ) == .deny("Membership snapshot is stale"),
        )
        _ = try peerAuthority.importSnapshot(snapshot, now: stale)
        #expect(
            peerAuthority.authorizeCertificate(
                hostId: "peer",
                fingerprint: peer.deviceFingerprint,
                now: stale,
            ) == .deny("Removed member certificate"),
        )
        let removed = try peerAuthority.load().members.first { $0.hostId == "peer" }
        #expect(removed?.status == "removed")
    }

    @Test func `local workloads ignore membership reachability`() {
        let authority = HomeMembershipAuthority(
            dataDir: URL(fileURLWithPath: "/tmp/unused-membership-\(UUID().uuidString)"),
        )
        #expect(authority.authorizeLocalWorkload(membershipAuthorityReachable: false) == .allow)
        #expect(LocalWorkloadPolicy.keepsRunning(membershipAuthorityReachable: false))
    }

    @Test func `interrupted pairing does not authorize and retry commits the bound key`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authority = HomeMembershipAuthority(dataDir: dir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try authority.beginAdmission(
            exchangeId: "offer-1",
            hostId: "joiner",
            fingerprint: "wanted",
            now: now,
        )
        #expect(
            authority.authorizeCertificate(hostId: "joiner", fingerprint: "wanted", now: now)
                == .deny("Pairing is not a committed membership"),
        )
        #expect(throws: BarkVisorError.self) {
            try authority.commitAdmission(
                exchangeId: "offer-1",
                hostId: "joiner",
                fingerprint: "other-key",
                now: now,
            )
        }
        try authority.abortAdmission(hostId: "joiner", exchangeId: "offer-1")
        #expect(try authority.load().members.isEmpty)

        try authority.beginAdmission(
            exchangeId: "offer-2",
            hostId: "joiner",
            fingerprint: "wanted",
            now: now,
        )
        try authority.commitAdmission(
            exchangeId: "offer-2",
            hostId: "joiner",
            fingerprint: "wanted",
            now: now,
        )
        #expect(
            authority.authorizeCertificate(hostId: "joiner", fingerprint: "wanted", now: now)
                == .allow,
        )
        #expect(
            authority.authorizeCertificate(hostId: "joiner", fingerprint: "other-key", now: now)
                == .deny("Certificate key is not the admitted Device key"),
        )
    }

    @Test func `rotation keeps an active member and refuses a removed one`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authority = HomeMembershipAuthority(dataDir: dir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try authority.beginAdmission(
            exchangeId: "ex", hostId: "peer", fingerprint: "old", now: now,
        )
        try authority.commitAdmission(
            exchangeId: "ex", hostId: "peer", fingerprint: "old", now: now,
        )
        _ = try authority.rotateDeviceKey(hostId: "peer", newFingerprint: "new", now: now)
        #expect(
            authority.authorizeCertificate(hostId: "peer", fingerprint: "new", now: now) == .allow,
        )
        #expect(
            authority.authorizeCertificate(hostId: "peer", fingerprint: "old", now: now)
                == .deny("Certificate key is not the admitted Device key"),
        )
        #expect(try authority.load().members.first?.status == "active")

        try authority.removeMember(hostId: "peer", localHostId: "self", now: now)
        #expect(throws: BarkVisorError.self) {
            try authority.rotateDeviceKey(hostId: "peer", newFingerprint: "revived", now: now)
        }
        #expect(try authority.load().members.first?.status == "removed")
        #expect(
            authority.authorizeCertificate(hostId: "peer", fingerprint: "revived", now: now)
                == .deny("Removed member certificate"),
        )
    }

    @Test func `migration retires a copied session key and keeps the passkey record`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Config.persistJWTSecret("shared-secret", to: dir)
        let receipt = PairingPeerReceipt(
            peerHostId: "issuer",
            peerFingerprint: "abc",
            caCertificatePEM: "ca",
            caFingerprint: "ca",
            issuedCertificatePEM: "leaf",
            issuedFingerprint: "leaf",
            pairedAt: "2026-01-01T00:00:00Z",
        )
        let url = dir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(PairingService.receiptFileName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try JSONEncoder().encode(receipt).write(to: url)
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try await pool.write { db in
            try User(
                id: "admin",
                username: "pascal",
                password: "",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "shared-secret"), digestAlgorithm: .sha256)
        let stale = try await keys.sign(
            UserPayload(
                sub: .init(value: "admin"),
                username: "pascal",
                exp: .init(value: Date().addingTimeInterval(600)),
            ),
        )

        try HomeMembershipAuthority.migrateExistingHome(dataDir: dir, localHostId: "self")
        let rotated = try #require(Config.loadJWTSecret(from: dir))
        #expect(rotated != "shared-secret")
        let freshKeys = JWTKeyCollection()
        await freshKeys.add(hmac: .init(from: rotated), digestAlgorithm: .sha256)
        await #expect(throws: Error.self) {
            try await freshKeys.verify(stale, as: UserPayload.self)
        }
        let admin = try await pool.read { db in try User.fetchOne(db, key: "admin") }
        #expect(admin?.username == "pascal")
        let again = try HomeMembershipAuthority(dataDir: dir).load()
        try HomeMembershipAuthority.migrateExistingHome(dataDir: dir, localHostId: "self")
        #expect(Config.loadJWTSecret(from: dir) == rotated)
        #expect(again.sharedSigningMaterialRetired)
    }

    @Test func `two devices pair authenticate rotate remove restart and repair`() throws {
        let issuerDir = try isolatedDir()
        let joinerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
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
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: issued.code,
                    hostId: joinerId,
                    csrPEM: csr,
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                    agentHost: "192.168.0.9",
                ),
                jwtSecret: "must-not-copy",
                adminUser: PairingAdminUser(
                    id: "admin",
                    username: "pascal",
                    passwordHash: "hashed",
                ),
            ),
            offers: offers,
        )
        let seal = try #require(remote.identitySeal)
        let identity = try PairingIdentitySealing.open(
            seal,
            joinerDeviceKeyPEM: joiner.deviceKeyPEM,
            issuerCertificatePEM: remote.deviceCertificatePEM,
            issuerHostId: issuerId,
            joinerHostId: joinerId,
        )
        #expect(identity.jwtSecret.isEmpty)

        let issuerAuthority = HomeMembershipAuthority(dataDir: issuerDir)
        let now = Date()
        #expect(
            issuerAuthority.authorizeCertificate(
                hostId: joinerId,
                fingerprint: joiner.deviceFingerprint,
                now: now,
            ) == .allow,
        )
        let revision = try issuerAuthority.currentRevision()
        let scoped = try HomeScopedCredential.sign(
            issuerHostId: joinerId,
            subject: "admin",
            username: "pascal",
            role: "admin",
            membershipRevision: revision,
            deviceKeyPEM: joiner.deviceKeyPEM,
            now: now,
        )
        let verified = try HomeScopedCredential.verify(
            token: scoped,
            issuerCertificatePEM: joiner.deviceCertificatePEM,
            now: now,
        )
        #expect(verified.issuerHostId == joinerId)
        #expect(
            issuerAuthority.authorizeLoginToken(
                issuerHostId: verified.issuerHostId,
                subjectHostId: nil,
                issuedAt: verified.issuedAt,
                expiresAt: verified.expiresAt,
                membershipRevision: verified.membershipRevision,
                localHostId: issuerId,
                now: now,
            ) == .allow,
        )

        _ = try issuerAuthority.rotateDeviceKey(
            hostId: joinerId,
            newFingerprint: "rotated-fingerprint",
            now: now,
        )
        #expect(
            issuerAuthority.authorizeCertificate(
                hostId: joinerId,
                fingerprint: joiner.deviceFingerprint,
                now: now,
            ) == .deny("Certificate key is not the admitted Device key"),
        )
        _ = try issuerAuthority.rotateDeviceKey(
            hostId: joinerId,
            newFingerprint: joiner.deviceFingerprint,
            now: now,
        )

        try HomeDeviceMembership.remove(
            hostId: joinerId,
            localHostId: issuerId,
            dataDir: issuerDir,
        )
        let restarted = HomeMembershipAuthority(dataDir: issuerDir)
        #expect(
            restarted.authorizeCertificate(
                hostId: joinerId,
                fingerprint: joiner.deviceFingerprint,
                now: now,
            ) == .deny("Removed member certificate"),
        )
        #expect(
            restarted.authorizeProxy(
                callerHostId: nil,
                targetHostId: joinerId,
                fingerprint: joiner.deviceFingerprint,
                localHostId: issuerId,
                now: now,
            ) == .deny("Removed member cannot be proxied"),
        )
        #expect(
            restarted.authorizeLoginToken(
                issuerHostId: joinerId,
                subjectHostId: joinerId,
                issuedAt: verified.issuedAt,
                expiresAt: verified.expiresAt,
                membershipRevision: verified.membershipRevision,
                localHostId: issuerId,
                now: now,
            ) == .deny("Removed member login token"),
        )

        let again = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
        )
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: again.code,
                    hostId: joinerId,
                    csrPEM: csr,
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                    agentHost: "192.168.0.9",
                ),
            ),
        )
        #expect(
            HomeMembershipAuthority(dataDir: issuerDir).authorizeCertificate(
                hostId: joinerId,
                fingerprint: joiner.deviceFingerprint,
                now: now,
            ) == .allow,
        )
    }

    @Test func `public server cannot write policy or mint management credentials`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authority = HomeMembershipAuthority(dataDir: dir)
        #expect(throws: BarkVisorError.self) {
            try authority.beginAdmission(
                exchangeId: "ex",
                hostId: "peer",
                fingerprint: "aa",
                writer: .publicServer,
            )
        }
        #expect(MembershipProcessBoundary.transportsAndAuthorityAreDisjoint)
        #expect(
            !MembershipProcessBoundary.canMintManagementCredential(
                readableRelativePaths: MembershipProcessBoundary.serverRelativePaths,
            ),
        )
        #expect(throws: BarkVisorError.self) {
            try authority.managementKeyPEM(writer: .publicServer)
        }
        let privateKey = try authority.managementKeyPEM()
        #expect(!MembershipProcessBoundary.serverRelativePaths.contains("authority/management.key"))
        let publicKey = try authority.managementPublicKeyPEM()
        let token = try HomeManagementCredential.sign(
            issuerHostId: "self",
            subject: "admin",
            username: "pascal",
            role: "admin",
            onBehalfOfHostId: "self",
            membershipRevision: 0,
            managementKeyPEM: privateKey,
        )
        let verified = try HomeManagementCredential.verify(
            token: token,
            managementPublicKeyPEM: publicKey,
        )
        #expect(verified.subject == "admin")
        #expect(ForwardedIdentity.rejects(headerNames: ["X-BarkVisor-Host-Id"]))
        #expect(!ForwardedIdentity.rejects(headerNames: ["Accept"]))
    }

    @Test func `revocation closes active privileged streams`() async {
        let closed = LockedFlag()
        let id = await PrivilegedStreamGate.shared.register(memberHostId: "peer") {
            closed.set()
        }
        let invalidated = await PrivilegedStreamGate.shared.invalidate(memberHostId: "peer")
        #expect(invalidated == [id])
        #expect(closed.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
