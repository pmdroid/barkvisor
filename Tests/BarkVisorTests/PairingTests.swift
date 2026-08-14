import Foundation
import Testing
import X509
@testable import BarkVisorCore

@Suite("Pairing (PAS-45)")
struct PairingTests {
    private func isolatedDir(_ label: String = "pair") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Issue + redeem

    @Test func `issue and redeem pins joiner and returns home ca trust material`() throws {
        let issuerDir = try isolatedDir("issuer")
        let joinerDir = try isolatedDir("joiner")
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
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        #expect(issued.hostId == issuerId)
        #expect(issued.fingerprint == issuer.deviceFingerprint)
        #expect(issued.qrPayload.contains(issued.code))
        #expect(issued.qrPayload.contains("192.0.2.8"))

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
                ),
            ),
            offers: offers,
        )
        #expect(remote.hostId == issuerId)
        #expect(remote.deviceFingerprint == issuer.deviceFingerprint)
        #expect(remote.caFingerprint == issuer.caFingerprint)
        #expect(!remote.issuedCertificatePEM.isEmpty)

        let pins = try PeerPinStore(dataDir: issuerDir).load()
        #expect(pins.contains { $0.hostId == joinerId && $0.fingerprint == joiner.deviceFingerprint })

        let issuedCert = try Certificate(pemEncoded: remote.issuedCertificatePEM)
        let ca = try Certificate(pemEncoded: remote.caCertificatePEM)
        #expect(DeviceTrust.isIssuedByHomeCA(leaf: issuedCert, ca: ca))
        #expect(DeviceTrust.hostId(from: issuedCert) == joinerId)

        let trust = DeviceTrust.evaluate(
            leafPEM: joiner.deviceCertificatePEM,
            homeCAPEM: issuer.caCertificatePEM,
            pins: pins,
        )
        guard case let .accepted(hostId, source) = trust else {
            Issue.record("issuer should accept pinned joiner")
            return
        }
        #expect(hostId == joinerId)
        #expect(source == .pinned)

        let stillIssuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        #expect(stillIssuer.deviceFingerprint == issuer.deviceFingerprint)
        let sqlite = issuerDir.appendingPathComponent("db.sqlite")
        #expect(!FileManager.default.fileExists(atPath: sqlite.path))
    }

    @Test func `redeem is single use and expired codes fail`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: isolatedDir("j"), hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let now = Date()
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
                ttl: 60,
                now: now,
            ),
            offers: offers,
        )
        let csr = try HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM)
        let request = PairingRedeemRequest(
            code: issued.code,
            hostId: joiner.hostId,
            csrPEM: csr,
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir, issuerHostId: issuerId, request: request, now: now,
            ),
            offers: offers,
        )
        #expect(throws: PairingError.expiredOrUsed) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir, issuerHostId: issuerId, request: request, now: now,
                ),
                offers: offers,
            )
        }

        let short = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
                ttl: 30,
                now: now,
            ),
            offers: offers,
        )
        let later = now.addingTimeInterval(31)
        #expect(throws: PairingError.expiredOrUsed) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: PairingRedeemRequest(
                        code: short.code,
                        hostId: joiner.hostId,
                        csrPEM: csr,
                        deviceCertificatePEM: joiner.deviceCertificatePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                    now: later,
                ),
                offers: offers,
            )
        }
    }

    @Test func `invalid csr does not consume the code`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: isolatedDir("j2"), hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        #expect(throws: PairingError.self) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: joiner.hostId,
                        csrPEM: "not-a-csr",
                        deviceCertificatePEM: joiner.deviceCertificatePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
        let csr = try HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM)
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: issued.code,
                    hostId: joiner.hostId,
                    csrPEM: csr,
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                ),
            ),
            offers: offers,
        )
        #expect(try offers.load()?.consumedAt != nil)
    }

    @Test func `csr for a different key than the presented cert is rejected`() throws {
        let dir = try isolatedDir()
        let otherDir = try isolatedDir("other-key")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: isolatedDir("j-key"), hostId: UUID().uuidString)
        let other = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        let foreignCSR = try HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: other.deviceKeyPEM)
        #expect(throws: PairingError.self) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: joiner.hostId,
                        csrPEM: foreignCSR,
                        deviceCertificatePEM: joiner.deviceCertificatePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
    }

    @Test func `pin persist failure does not consume the code`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: isolatedDir("j-pin"), hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        let blocked = dir.appendingPathComponent("blocked-pins")
        try Data("not-a-directory".utf8).write(to: blocked, options: [.atomic])
        let pins = PeerPinStore(fileURL: blocked.appendingPathComponent("pins.json"))
        let csr = try HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM)
        #expect(throws: PairingError.self) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: joiner.hostId,
                        csrPEM: csr,
                        deviceCertificatePEM: joiner.deviceCertificatePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                ),
                offers: offers,
                pins: pins,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
        let retryPins = PeerPinStore(dataDir: dir)
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: issued.code,
                    hostId: joiner.hostId,
                    csrPEM: csr,
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                ),
            ),
            offers: offers,
            pins: retryPins,
        )
        #expect(try offers.load()?.consumedAt != nil)
    }

    @Test func `self pair and api version mismatch are rejected`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        let csr = try HomeCAService.makeDeviceCSR(hostId: hostId, keyPEM: material.deviceKeyPEM)
        #expect(throws: PairingError.selfPair) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: hostId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: hostId,
                        csrPEM: csr,
                        deviceCertificatePEM: material.deviceCertificatePEM,
                        caCertificatePEM: material.caCertificatePEM,
                    ),
                ),
                offers: offers,
            )
        }
        #expect(throws: PairingError.self) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: hostId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: UUID().uuidString,
                        csrPEM: csr,
                        deviceCertificatePEM: material.deviceCertificatePEM,
                        caCertificatePEM: material.caCertificatePEM,
                        apiVersion: APIContract.version + 1,
                    ),
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
    }

    @Test func `join apply pins issuer and rejects fingerprint swap`() throws {
        let issuerDir = try isolatedDir("iss")
        let joinerDir = try isolatedDir("join")
        let attackerDir = try isolatedDir("atk")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
            try? FileManager.default.removeItem(at: attackerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let attacker = try HomeCAService.loadOrCreate(dataDir: attackerDir, hostId: UUID().uuidString)
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.0.2.9",
            port: 7_777,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        let honest = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        let joined = try PairingService.applyTrust(
            response: honest,
            expected: payload,
            dataDir: joinerDir,
            localHostId: joinerId,
        )
        #expect(joined.peerHostId == issuerId)
        #expect(joined.pinned)
        #expect(joined.agentPort == 7_778)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: issuer.deviceFingerprint))
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.peerHostId == issuerId)
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.agentPort == 7_778)

        let swapped = PairingRedeemResponse(
            hostId: issuerId,
            deviceCertificatePEM: attacker.deviceCertificatePEM,
            deviceFingerprint: attacker.deviceFingerprint,
            caCertificatePEM: attacker.caCertificatePEM,
            caFingerprint: attacker.caFingerprint,
            issuedCertificatePEM: attacker.deviceCertificatePEM,
            issuedFingerprint: attacker.deviceFingerprint,
            agentPort: 7_778,
        )
        let otherDir = try isolatedDir("join2")
        defer { try? FileManager.default.removeItem(at: otherDir) }
        #expect(throws: PairingError.fingerprintMismatch) {
            try PairingService.applyTrust(
                response: swapped,
                expected: payload,
                dataDir: otherDir,
                localHostId: joinerId,
            )
        }
        #expect(try PeerPinStore(dataDir: otherDir).load().isEmpty)
        #expect(try PairingService.loadReceipt(dataDir: otherDir) == nil)
    }

    @Test func `join apply rejects attacker CA with matching QR fingerprint`() throws {
        let issuerDir = try isolatedDir("iss-mitm")
        let joinerDir = try isolatedDir("join-mitm")
        let attackerDir = try isolatedDir("atk-mitm")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
            try? FileManager.default.removeItem(at: attackerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let attacker = try HomeCAService.loadOrCreate(dataDir: attackerDir, hostId: UUID().uuidString)
        let attackerIssued = try HomeCAService.issueDeviceCert(
            hostId: joinerId,
            csrPEM: HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM),
            material: attacker,
        )
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.0.2.9",
            port: 7_777,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        let mitm = PairingRedeemResponse(
            hostId: issuerId,
            deviceCertificatePEM: issuer.deviceCertificatePEM,
            deviceFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: attacker.caCertificatePEM,
            caFingerprint: attacker.caFingerprint,
            issuedCertificatePEM: attackerIssued.certificatePEM,
            issuedFingerprint: attackerIssued.fingerprint,
            agentPort: 7_778,
        )
        #expect(throws: PairingError.self) {
            try PairingService.applyTrust(
                response: mitm,
                expected: payload,
                dataDir: joinerDir,
                localHostId: joinerId,
            )
        }
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
        #expect(try PairingService.loadReceipt(dataDir: joinerDir) == nil)
    }

    @Test func `join apply rejects issued cert whose SAN is not the joiner`() throws {
        let issuerDir = try isolatedDir("iss-san")
        let joinerDir = try isolatedDir("join-san")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let otherIssued = try HomeCAService.issueDeviceCert(
            hostId: UUID().uuidString,
            material: issuer,
        )
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.0.2.9",
            port: 7_777,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        let wrongSAN = PairingRedeemResponse(
            hostId: issuerId,
            deviceCertificatePEM: issuer.deviceCertificatePEM,
            deviceFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: otherIssued.certificatePEM,
            issuedFingerprint: otherIssued.fingerprint,
            agentPort: 7_778,
        )
        #expect(throws: PairingError.self) {
            try PairingService.applyTrust(
                response: wrongSAN,
                expected: payload,
                dataDir: joinerDir,
                localHostId: joinerId,
            )
        }
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
    }

    @Test func `join via mock client records pin without sqlite`() async throws {
        let issuerDir = try isolatedDir("iss-http")
        let joinerDir = try isolatedDir("join-http")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        _ = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.0.2.20",
                advertisedHosts: ["192.0.2.20"],
            ),
            offers: offers,
        )
        let client = InMemoryRedeemClient { body in
            let request = try JSONDecoder().decode(PairingRedeemRequest.self, from: body)
            return try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: issuerDir,
                    issuerHostId: issuerId,
                    request: request,
                ),
                offers: offers,
            )
        }
        let result = try await PairingService.join(
            request: PairingJoinRequest(qrPayload: issued.qrPayload),
            dataDir: joinerDir,
            hostId: joinerId,
            client: client,
        )
        #expect(result.peerHostId == issuerId)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: issuer.deviceFingerprint))
        #expect(try PeerPinStore(dataDir: issuerDir).pin(forHostId: joinerId) != nil)
        #expect(!FileManager.default.fileExists(atPath: joinerDir.appendingPathComponent("db.sqlite").path))

        let local = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        #expect(local.caFingerprint != issuer.caFingerprint)
    }

    @Test func `join rejects incompatible GET contract without redeeming`() async throws {
        let issuerDir = try isolatedDir("iss-contract")
        let joinerDir = try isolatedDir("join-contract")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        _ = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.0.2.21",
                advertisedHosts: ["192.0.2.21"],
            ),
            offers: offers,
        )
        let client = InMemoryRedeemClient(contractVersion: APIContract.version + 1) { _ in
            Issue.record("redeem must not run after a contract mismatch")
            throw PairingError.unavailable("redeem should not be called")
        }
        await #expect(throws: PairingError.incompatibleAPIVersion(
            got: APIContract.version + 1,
            expected: APIContract.version,
        )) {
            try await PairingService.join(
                request: PairingJoinRequest(qrPayload: issued.qrPayload),
                dataDir: joinerDir,
                hostId: joinerId,
                client: client,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
        #expect(try PairingService.loadReceipt(dataDir: joinerDir) == nil)
    }

    @Test func `corrupt offer file does not remint a new code`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let offers = PairingOfferStore(dataDir: dir)
        _ = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: UUID().uuidString,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        let before = try Data(contentsOf: offers.fileURL)
        try Data("{".utf8).write(to: offers.fileURL, options: [.atomic])
        #expect(throws: PairingError.self) {
            try offers.load()
        }
        #expect(try Data(contentsOf: offers.fileURL) != before)
        #expect(try Data(contentsOf: offers.fileURL) == Data("{".utf8))
    }

    @Test func `offer file is 0600`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let offers = PairingOfferStore(dataDir: dir)
        _ = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: UUID().uuidString,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: offers.fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }

    @Test func `makeDeviceCSR is signed by the device key`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let pem = try HomeCAService.makeDeviceCSR(hostId: hostId, keyPEM: material.deviceKeyPEM)
        let csr = try CertificateSigningRequest(pemEncoded: pem)
        #expect(csr.publicKey.isValidSignature(csr.signature, for: csr))
        let issued = try HomeCAService.issueDeviceCert(
            hostId: hostId,
            csrPEM: pem,
            material: material,
        )
        #expect(issued.privateKeyPEM == nil)
        #expect(try DeviceTrust.hostId(from: Certificate(pemEncoded: issued.certificatePEM)) == hostId)
    }

    @Test func `revoke and current offer`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let offers = PairingOfferStore(dataDir: dir)
        let input = PairingService.IssueInput(
            dataDir: dir,
            hostId: hostId,
            advertisedHost: "192.0.2.8",
            advertisedHosts: ["192.0.2.8"],
        )
        _ = try PairingService.issue(input, offers: offers)
        #expect(try PairingService.currentOffer(input, offers: offers).code.isEmpty == false)
        try PairingService.revoke(dataDir: dir, offers: offers)
        #expect(throws: PairingError.noActiveOffer) {
            try PairingService.currentOffer(input, offers: offers)
        }
    }

    @Test func `current offer sanitizes advertised host like issue`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let offers = PairingOfferStore(dataDir: dir)
        _ = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        let current = try PairingService.currentOffer(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "http://evil.example",
                advertisedHosts: ["192.0.2.8"],
            ),
            offers: offers,
        )
        #expect(!current.qrPayload.contains("evil"))
        #expect(current.qrPayload.contains("192.0.2.8"))
    }

    @Test func `qr join path ignores host and port overrides`() throws {
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.0.2.10",
            port: 7_777,
            hostId: "host-a",
            fingerprint: "abcd",
        )
        let resolved = try PairingService.resolveJoinPayload(
            PairingJoinRequest(
                qrPayload: payload.uri,
                host: "198.51.100.1",
                port: 0,
            ),
        )
        #expect(resolved.host == "192.0.2.10")
        #expect(resolved.port == 7_777)
        #expect(resolved.fingerprint == "abcd")
        #expect(throws: PairingError.self) {
            try PairingService.resolveJoinPayload(
                PairingJoinRequest(
                    code: "ABCD-EFGH",
                    host: "192.0.2.10",
                    port: 7_777,
                    hostId: "host-a",
                    fingerprint: "abcd",
                ),
            )
        }
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

private struct InMemoryRedeemClient: PairingHTTPClient {
    var contractVersion: Int = APIContract.version
    let handler: @Sendable (Data) throws -> PairingRedeemResponse

    func get(url: URL) async throws -> PairingHTTPResponse {
        #expect(url.path == "/api/contract")
        #expect(url.scheme == "http")
        struct Probe: Encodable {
            var apiVersion: Int
        }
        return try PairingHTTPResponse(
            status: 200,
            body: JSONEncoder().encode(Probe(apiVersion: contractVersion)),
        )
    }

    func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
        #expect(url.path == "/api/pairing/redeem")
        #expect(url.scheme == "http")
        let response = try handler(body)
        return try PairingHTTPResponse(status: 200, body: JSONEncoder().encode(response))
    }
}
