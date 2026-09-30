import Foundation
import Testing
import X509
@testable import BarkVisor
@testable import BarkVisorCore

/// Renewal of the Home-issued leaf a paired Device presents (#740).
@Suite("Home certificate renewal", .serialized)
struct HomeCertificateRenewalTests {
    private typealias Fixtures = RenewalFixtures

    // MARK: - Pairing admits the issued leaf

    @Test func `pairing admits the certificate the Home issued`() async throws {
        let issuerDir = try RenewalFixtures.isolatedDir("iss")
        let joinerDir = try RenewalFixtures.isolatedDir("join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let (issuer, joiner, issued) = try await RenewalFixtures.pair(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
        )

        let authority = HomeMembershipAuthority(dataDir: issuerDir)
        #expect(
            try authority.memberFingerprints(hostId: joinerId)
                == [joiner.deviceFingerprint, issued.issuedFingerprint],
        )
        #expect(
            try PeerPinStore(dataDir: issuerDir).fingerprints(forHostId: joinerId)
                == [joiner.deviceFingerprint, issued.issuedFingerprint],
        )
        #expect(
            authority.authorizeCertificate(
                hostId: joinerId,
                fingerprint: issued.issuedFingerprint,
                localHostId: issuerId,
            ) == .allow,
        )
        // The Home keeps its own leaf, and the joiner pins only the Home.
        #expect(
            authority.authorizeCertificate(
                hostId: issuerId,
                fingerprint: issuer.deviceFingerprint,
                localHostId: issuerId,
            ) == .allow,
        )
        #expect(
            try PeerPinStore(dataDir: joinerDir).fingerprints(forHostId: issuerId)
                == [issuer.deviceFingerprint],
        )
    }

    // MARK: - The exchange

    @Test func `member renews its Home-issued certificate over the agent plane`() async throws {
        let issuerDir = try RenewalFixtures.isolatedDir("iss")
        let joinerDir = try RenewalFixtures.isolatedDir("join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let (issuer, joiner, issued) = try await RenewalFixtures.pair(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
        )
        let before = try #require(try PairingService.loadReceipt(dataDir: joinerDir))
        #expect(before.issuedFingerprint == issued.issuedFingerprint)
        #expect(before.renewedAt == nil)
        let keyBefore = try String(
            contentsOf: HomeCAService.agentDirectory(in: joinerDir)
                .appendingPathComponent(HomeCAService.deviceKeyFileName),
            encoding: .utf8,
        )

        let server = AgentTLSServer(
            material: issuer,
            pins: PeerPinStore(dataDir: issuerDir),
            hostname: "127.0.0.1",
            port: 0,
            dataDir: issuerDir,
            hostId: issuerId,
        )
        try await server.start()
        do {
            let port = try #require(server.boundPort)
            try DeviceRegistry(dataDir: joinerDir).upsert(
                hostId: issuerId,
                fingerprint: issuer.deviceFingerprint,
                agentHost: "127.0.0.1",
                agentPort: port,
            )
            let outcome = await HomeCertificateRenewalClient.renew(
                dataDir: joinerDir,
                hostId: joinerId,
                client: RenewalFixtures.memberClient(material: joiner, receipt: before),
            )
            let renewed = try #require(outcome.renewedFingerprint)
            #expect(renewed != before.issuedFingerprint)

            // Identity and data survive: same Device, same key, same Home.
            let after = try #require(try PairingService.loadReceipt(dataDir: joinerDir))
            #expect(after.issuedFingerprint == renewed)
            #expect(after.renewedAt != nil)
            #expect(after.peerHostId == before.peerHostId)
            #expect(after.peerFingerprint == before.peerFingerprint)
            #expect(after.caFingerprint == before.caFingerprint)
            #expect(after.caCertificatePEM == before.caCertificatePEM)
            #expect(after.agentPort == before.agentPort)
            #expect(after.pairedAt == before.pairedAt)
            #expect(
                try String(
                    contentsOf: HomeCAService.agentDirectory(in: joinerDir)
                        .appendingPathComponent(HomeCAService.deviceKeyFileName),
                    encoding: .utf8,
                ) == keyBefore,
            )
            // The new leaf is the one this Device presents, signed by the Home.
            let material = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
            #expect(material.hostId == joinerId)
            #expect(
                try DeviceTrust.hostId(from: Certificate(pemEncoded: material.deviceCertificatePEM))
                    == joinerId,
            )
            let presented = try AgentPlaneCertificates.presentationCertificatePEM(
                material: material,
                receipt: after,
            )
            #expect(presented == after.issuedCertificatePEM)
            let leaf = try Certificate(pemEncoded: after.issuedCertificatePEM)
            let ca = try Certificate(pemEncoded: issuer.caCertificatePEM)
            #expect(DeviceTrust.isIssuedByHomeCA(leaf: leaf, ca: ca))
            #expect(DeviceTrust.hostId(from: leaf) == joinerId)
            #expect(
                AgentPlaneCertificates.certificateMatchesKey(
                    after.issuedCertificatePEM,
                    keyPEM: material.deviceKeyPEM,
                ),
            )

            // The Home admitted it: membership and pins moved together, and
            // both survive a restart of the process that owns them.
            let restarted = HomeMembershipAuthority(dataDir: issuerDir)
            #expect(
                restarted.authorizeCertificate(
                    hostId: joinerId,
                    fingerprint: renewed,
                    localHostId: issuerId,
                ) == .allow,
            )
            #expect(
                try restarted.memberFingerprints(hostId: joinerId).contains(renewed),
            )
            #expect(
                try PeerPinStore(dataDir: issuerDir).fingerprints(forHostId: joinerId)
                    == (restarted.memberFingerprints(hostId: joinerId)),
            )
            #expect(
                try PeerPinStore(dataDir: issuerDir).contains(fingerprint: renewed),
            )
            // The superseded leaf stays admitted for one more renewal so a
            // lost response can be retried.
            #expect(
                try restarted.memberFingerprints(hostId: joinerId).contains(issued.issuedFingerprint),
            )
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `the Home refuses a CSR for another key`() async throws {
        let dirs = try await RenewalFixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let strangerDir = try RenewalFixtures.isolatedDir("stranger")
        defer { try? FileManager.default.removeItem(at: strangerDir) }
        let other = try HomeCAService.loadOrCreate(
            dataDir: strangerDir,
            hostId: UUID().uuidString,
        )
        let request = try AgentCertificateRenewRequest(
            hostId: dirs.joinerId,
            csrPEM: HomeCAService.makeDeviceCSR(
                hostId: dirs.joinerId,
                keyPEM: other.deviceKeyPEM,
            ),
        )
        #expect(throws: CertificateRenewalError.keyMismatch) {
            try dirs.renew(request: request)
        }
    }

    @Test func `the Home refuses a renewal that claims another Device`() async throws {
        let dirs = try await RenewalFixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let request = AgentCertificateRenewRequest(
            hostId: UUID().uuidString,
            csrPEM: dirs.csrPEM,
        )
        #expect(throws: CertificateRenewalError.hostMismatch) {
            try dirs.renew(request: request)
        }
    }

    @Test func `the Home refuses a removed member`() async throws {
        let issuerDir = try RenewalFixtures.isolatedDir("iss")
        let joinerDir = try RenewalFixtures.isolatedDir("join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let (_, joiner, issued) = try await RenewalFixtures.pair(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
        )
        try HomeDeviceMembership.remove(
            hostId: joinerId,
            localHostId: issuerId,
            dataDir: issuerDir,
        )
        #expect(throws: CertificateRenewalError.memberDenied("Removed member certificate")) {
            try RenewalFixtures.issue(
                issuerDir: issuerDir,
                issuerId: issuerId,
                joinerId: joinerId,
                presentedPEM: issued.issuedCertificatePEM,
                presentedFingerprint: issued.issuedFingerprint,
                csrPEM: HomeCAService.makeDeviceCSR(
                    hostId: joinerId,
                    keyPEM: joiner.deviceKeyPEM,
                ),
            )
        }
    }

    /// A renewal whose response never arrived is retried with the same
    /// certificate; both attempts must be admitted and the record must stay
    /// bounded however often this happens.
    @Test func `a lost response can be retried with the previous certificate`() async throws {
        let issuerDir = try RenewalFixtures.isolatedDir("iss")
        let joinerDir = try RenewalFixtures.isolatedDir("join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let (_, joiner, issued) = try await RenewalFixtures.pair(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
        )
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        var presented = issued.issuedCertificatePEM
        var presentedFingerprint = issued.issuedFingerprint
        var admitted: [String] = []
        for _ in 0 ..< 4 {
            let response = try RenewalFixtures.issue(
                issuerDir: issuerDir,
                issuerId: issuerId,
                joinerId: joinerId,
                presentedPEM: presented,
                presentedFingerprint: presentedFingerprint,
                csrPEM: csr,
            )
            // The member never saw the first answer, so it presents the old
            // leaf again: that leaf must still be authorized.
            #expect(
                HomeMembershipAuthority(dataDir: issuerDir).authorizeCertificate(
                    hostId: joinerId,
                    fingerprint: presentedFingerprint,
                    localHostId: issuerId,
                ) == .allow,
            )
            presented = response.certificatePEM
            presentedFingerprint = response.fingerprint
            admitted = try HomeMembershipAuthority(dataDir: issuerDir)
                .memberFingerprints(hostId: joinerId)
            #expect(admitted.count <= HomeCertificateRenewal.admittedFingerprintsPerMember)
            #expect(
                try PeerPinStore(dataDir: issuerDir).fingerprints(forHostId: joinerId) == admitted,
            )
        }
        #expect(admitted.count == HomeCertificateRenewal.admittedFingerprintsPerMember)
        #expect(admitted.first == joiner.deviceFingerprint)
        #expect(admitted.last == presentedFingerprint)
    }

    @Test func `admitted fingerprints stay bounded`() {
        // The pairing fingerprint, the leaf the member holds, and the new one.
        #expect(
            HomeCertificateRenewal.admittedFingerprints(
                previous: ["base", "issued"],
                superseding: "issued",
                issued: "next",
            ) == ["base", "issued", "next"],
        )
        // Full: the superseded history is dropped, never the live leaf.
        #expect(
            HomeCertificateRenewal.admittedFingerprints(
                previous: ["base", "older", "issued"],
                superseding: "issued",
                issued: "next",
            ) == ["base", "issued", "next"],
        )
        // A member retrying with a leaf two renewals old keeps that leaf.
        #expect(
            HomeCertificateRenewal.admittedFingerprints(
                previous: ["base", "a", "b", "c"],
                superseding: "a",
                issued: "d",
            ) == ["base", "a", "d"],
        )
        #expect(
            HomeCertificateRenewal.admittedFingerprints(
                previous: ["base", "a", "b", "c"],
                superseding: "c",
                issued: "d",
            ) == ["base", "c", "d"],
        )
        #expect(
            HomeCertificateRenewal.admittedFingerprints(
                previous: ["base"],
                superseding: "unknown",
                issued: "next",
            ) == ["base", "next"],
        )
    }

    // MARK: - Expiry boundaries

    @Test func `renewal starts at the window boundary and not before`() throws {
        let dir = try RenewalFixtures.isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let cert = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString, now: now)
        let leaf = try Certificate(pemEncoded: cert.deviceCertificatePEM)
        let window = HomeCertificateRenewal.renewalWindow
        #expect(window == HomeCAService.deviceRenewalWindow)
        #expect(
            !HomeCertificateRenewal.renewalDue(
                issuedCertificatePEM: cert.deviceCertificatePEM,
                now: leaf.notValidAfter.addingTimeInterval(-window - 60),
            ),
        )
        #expect(
            HomeCertificateRenewal.renewalDue(
                issuedCertificatePEM: cert.deviceCertificatePEM,
                now: leaf.notValidAfter.addingTimeInterval(-window + 60),
            ),
        )
        // A leaf that cannot be read is renewed: the exchange is the only way
        // to replace it.
        #expect(HomeCertificateRenewal.renewalDue(issuedCertificatePEM: "not a pem", now: now))
    }

    @Test func `the renewal endpoint is only on the agent plane`() {
        #expect(HomeCertificateRenewal.endpointPath == "/api/agent/certificates/renew")
        // Pairing and setup stay console-local; the exchange must not be
        // reachable through the Home proxy.
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/agent/certificates/renew") == false)
        #expect(
            (try? HomeDeviceProxy.memberURL(
                host: "192.168.0.8",
                port: 7_778,
                path: HomeCertificateRenewal.endpointPath,
            ))?.path == HomeCertificateRenewal.endpointPath,
        )
    }

    // MARK: - Member side outcomes and retries

    // MARK: - Member side outcomes

    @Test func `an unpaired Device has nothing to renew`() async throws {
        let dir = try Fixtures.isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let outcome = await HomeCertificateRenewalClient.renew(
            dataDir: dir,
            hostId: hostId,
            client: Fixtures.StubRenewalClient(status: 200, body: Data()),
        )
        #expect(outcome == .notPaired)
    }

    @Test func `a Home that cannot renew keeps the issued certificate`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let before = try #require(try PairingService.loadReceipt(dataDir: dirs.joinerDir))
        // 1.0.0-alpha.13 has no renewal route and answers 404.
        let outcome = await HomeCertificateRenewalClient.renew(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            client: Fixtures.StubRenewalClient(status: 404, body: Data()),
        )
        #expect(outcome == .unsupportedIssuer)
        #expect(try PairingService.loadReceipt(dataDir: dirs.joinerDir) == before)
        #expect(
            try AgentPlaneCertificates.presentationCertificatePEM(
                material: dirs.joiner,
                receipt: before,
            ) == before.issuedCertificatePEM,
        )
        #expect(
            CertificateRenewalRetryPolicy.delay(after: .unsupportedIssuer, failedAttempts: 1)
                == CertificateRenewalRetryPolicy.unsupportedIssuerDelay,
        )
    }

    @Test func `an offline Home is retried on a growing backoff`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let before = try #require(try PairingService.loadReceipt(dataDir: dirs.joinerDir))
        let loop = HomeCertificateRenewalLoop(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            clientProvider: { Fixtures.StubRenewalClient.failing() },
        )
        let now = Date()
        guard case let .issuerUnreachable(reason) = await loop.tick(now: now) else {
            Issue.record("an offline Home must report as unreachable")
            return
        }
        #expect(reason == "Device is unreachable: offline")
        #expect(try PairingService.loadReceipt(dataDir: dirs.joinerDir) == before)
        let firstDelay = await loop.delayUntilNextAttempt(now: now)
        #expect(firstDelay == CertificateRenewalRetryPolicy.baseUnreachableDelay)
        // A tick inside the backoff window does nothing at all.
        #expect(await loop.tick(now: now.addingTimeInterval(60)) == nil)
        guard case .issuerUnreachable = await loop.tick(
            now: now.addingTimeInterval(firstDelay + 1),
        ) else {
            Issue.record("the backoff must expire and retry")
            return
        }
        let secondDelay = await loop.delayUntilNextAttempt(now: now.addingTimeInterval(firstDelay + 1))
        #expect(secondDelay == firstDelay * 2)
        #expect(
            CertificateRenewalRetryPolicy.delay(
                after: .issuerUnreachable("x"),
                failedAttempts: 99,
            ) == CertificateRenewalRetryPolicy.maximumUnreachableDelay,
        )
    }

    @Test func `a restart clears the renewal backoff`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let now = Date()
        let loop = HomeCertificateRenewalLoop(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            clientProvider: { Fixtures.StubRenewalClient(status: 404, body: Data()) },
        )
        #expect(await loop.tick(now: now) == .unsupportedIssuer)
        #expect(await loop.delayUntilNextAttempt(now: now) > 0)
        // A fresh process starts from zero and tries again straight away.
        let restarted = HomeCertificateRenewalLoop(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            clientProvider: { Fixtures.StubRenewalClient(status: 404, body: Data()) },
        )
        #expect(await restarted.delayUntilNextAttempt(now: now) == 0)
        #expect(await restarted.tick(now: now) == .unsupportedIssuer)
    }

    @Test func `a leaf outside the window is left alone`() async throws {
        let dirs = try await Fixtures.renewalFixture(fresh: true)
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let asked = Fixtures.AttemptCounter()
        let loop = HomeCertificateRenewalLoop(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            clientProvider: {
                asked.increment()
                return Fixtures.StubRenewalClient(status: 500, body: Data())
            },
        )
        let fresh = Date()
        guard case let .notDue(validUntil) = await loop.tick(now: fresh) else {
            Issue.record("a fresh certificate must not be renewed")
            return
        }
        #expect(validUntil > fresh)
        #expect(asked.value == 0)
        #expect(await loop.delayUntilNextAttempt(now: fresh) == 0)
    }

    @Test func `a refused renewal changes nothing`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let before = try #require(try PairingService.loadReceipt(dataDir: dirs.joinerDir))
        let outcome = await HomeCertificateRenewalClient.renew(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            client: Fixtures.StubRenewalClient(
                status: 403,
                body: Data(#"{"reason":"Removed member certificate"}"#.utf8),
            ),
        )
        #expect(outcome == .denied("Removed member certificate"))
        #expect(try PairingService.loadReceipt(dataDir: dirs.joinerDir) == before)
        #expect(
            CertificateRenewalRetryPolicy.delay(after: .denied("x"), failedAttempts: 1)
                == CertificateRenewalRetryPolicy.deniedDelay,
        )
    }

    @Test func `a response from another Home is refused`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let before = try #require(try PairingService.loadReceipt(dataDir: dirs.joinerDir))
        let strangerDir = try Fixtures.isolatedDir("stranger")
        defer { try? FileManager.default.removeItem(at: strangerDir) }
        let stranger = try HomeCAService.loadOrCreate(dataDir: strangerDir, hostId: UUID().uuidString)
        let response = AgentCertificateRenewResponse(
            hostId: before.peerHostId,
            certificatePEM: stranger.deviceCertificatePEM,
            fingerprint: stranger.deviceFingerprint,
            caCertificatePEM: stranger.caCertificatePEM,
            caFingerprint: stranger.caFingerprint,
            notValidAfter: iso8601.string(from: Date().addingTimeInterval(3_600)),
            membershipRevision: 1,
        )
        let outcome = try await HomeCertificateRenewalClient.renew(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            client: Fixtures.StubRenewalClient(status: 200, body: JSONEncoder().encode(response)),
        )
        guard case .failed = outcome else {
            Issue.record("a certificate from another Home must be refused: \(outcome)")
            return
        }
        #expect(try PairingService.loadReceipt(dataDir: dirs.joinerDir) == before)
    }

    @Test func `an expired renewal response is refused`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let before = try #require(try PairingService.loadReceipt(dataDir: dirs.joinerDir))
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        let stale = try HomeCAService.loadOrCreate(
            dataDir: dirs.issuerDir,
            hostId: dirs.issuerId,
            now: longAgo.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600)),
        )
        // Re-issuing against the pair-time Home CA material: the joiner only
        // accepts a certificate that is valid now.
        let expired = try HomeCAService.issueDeviceCert(
            hostId: dirs.joinerId,
            csrPEM: HomeCAService.makeDeviceCSR(
                hostId: dirs.joinerId,
                keyPEM: dirs.joiner.deviceKeyPEM,
            ),
            material: stale,
            now: longAgo,
        )
        let response = AgentCertificateRenewResponse(
            hostId: before.peerHostId,
            certificatePEM: expired.certificatePEM,
            fingerprint: expired.fingerprint,
            caCertificatePEM: stale.caCertificatePEM,
            caFingerprint: stale.caFingerprint,
            notValidAfter: iso8601.string(from: expired.notValidAfter),
            membershipRevision: 1,
        )
        let outcome = try await HomeCertificateRenewalClient.renew(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            client: Fixtures.StubRenewalClient(status: 200, body: JSONEncoder().encode(response)),
        )
        guard case .failed = outcome else {
            Issue.record("an expired certificate must be refused: \(outcome)")
            return
        }
        #expect(try PairingService.loadReceipt(dataDir: dirs.joinerDir) == before)
    }

    @Test func `a member without a known Home address reports it`() async throws {
        let dirs = try await Fixtures.renewalFixture()
        defer {
            try? FileManager.default.removeItem(at: dirs.issuerDir)
            try? FileManager.default.removeItem(at: dirs.joinerDir)
        }
        let before = try #require(try PairingService.loadReceipt(dataDir: dirs.joinerDir))
        try DeviceRegistry(dataDir: dirs.joinerDir).remove(hostId: dirs.issuerId)
        let outcome = await HomeCertificateRenewalClient.renew(
            dataDir: dirs.joinerDir,
            hostId: dirs.joinerId,
            client: Fixtures.StubRenewalClient(status: 200, body: Data()),
        )
        guard case let .failed(reason) = outcome else {
            Issue.record("an unknown Home address must be reported: \(outcome)")
            return
        }
        #expect(reason.contains("re-pair"))
        #expect(try PairingService.loadReceipt(dataDir: dirs.joinerDir) == before)
    }
}
