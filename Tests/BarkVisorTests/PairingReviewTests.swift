import Foundation
import Testing
import X509
@testable import BarkVisorCore

@Suite("Pairing review (PAS-45)")
struct PairingReviewTests {
    private func isolatedDir(_ label: String = "pair-rev") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `concurrent redeem of one code pins a single joiner`() throws {
        let dir = try isolatedDir()
        let joinerADir = try isolatedDir("ja")
        let joinerBDir = try isolatedDir("jb")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerADir)
            try? FileManager.default.removeItem(at: joinerBDir)
        }
        let issuerId = UUID().uuidString
        let joinerA = try HomeCAService.loadOrCreate(dataDir: joinerADir, hostId: UUID().uuidString)
        let joinerB = try HomeCAService.loadOrCreate(dataDir: joinerBDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let requestA = try redeemRequest(code: issued.code, joiner: joinerA)
        let requestB = try redeemRequest(code: issued.code, joiner: joinerB)
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var outcomes: [Result<PairingRedeemResponse, Error>] = []
        }
        let box = Box()
        let group = DispatchGroup()
        for request in [requestA, requestB] {
            group.enter()
            DispatchQueue.global().async {
                let result = Result {
                    try PairingService.redeem(
                        PairingService.RedeemInput(
                            dataDir: dir,
                            issuerHostId: issuerId,
                            request: request,
                        ),
                        offers: offers,
                    )
                }
                box.lock.lock()
                box.outcomes.append(result)
                box.lock.unlock()
                group.leave()
            }
        }
        group.wait()
        let wins = box.outcomes.compactMap { try? $0.get() }
        #expect(wins.count == 1)
        let pins = try PeerPinStore(dataDir: dir).load()
        #expect(pins.count == 1)
        #expect(try offers.load()?.consumedAt != nil)
    }

    @Test func `redeem returns the issued agentPort`() throws {
        let dir = try isolatedDir()
        let joinerDir = try isolatedDir("jp")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                agentPort: 9_123,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        #expect(issued.agentPort == 9_123)
        #expect(issued.qrPayload.contains("agentPort=9123"))
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir,
                issuerHostId: issuerId,
                request: redeemRequest(code: issued.code, joiner: joiner),
            ),
            offers: offers,
        )
        #expect(remote.agentPort == 9_123)
    }

    @Test func `consumed code rejects a different joiner`() throws {
        let dir = try isolatedDir()
        let joinerDir = try isolatedDir("ja")
        let otherDir = try isolatedDir("jb")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerDir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let other = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir,
                issuerHostId: issuerId,
                request: redeemRequest(code: issued.code, joiner: joiner),
            ),
            offers: offers,
        )
        #expect(throws: PairingError.expiredOrUsed) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: redeemRequest(code: issued.code, joiner: other),
                ),
                offers: offers,
            )
        }
        #expect(try PeerPinStore(dataDir: dir).load().count == 1)
    }

    @Test func `receipt persist failure does not leave a peer pin`() throws {
        let issuerDir = try isolatedDir("iss-receipt")
        let joinerDir = try isolatedDir("join-receipt")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
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
        let honest = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        let receiptURL = PairingService.receiptURL(in: joinerDir)
        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
        #expect(throws: PairingError.self) {
            try PairingService.applyTrust(
                response: honest,
                expected: payload,
                dataDir: joinerDir,
                localHostId: joinerId,
            )
        }
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
    }

    @Test func `join retries applyTrust from pending redeem without posting again`() async throws {
        let issuerDir = try isolatedDir("iss-pending")
        let joinerDir = try isolatedDir("join-pending")
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
                advertisedHost: "192.168.0.22",
                advertisedHosts: ["192.168.0.22"],
            ),
            offers: offers,
        )
        final class CountingClient: PairingHTTPClient, @unchecked Sendable {
            var posts = 0
            let handler: @Sendable (Data) throws -> PairingRedeemResponse
            init(handler: @escaping @Sendable (Data) throws -> PairingRedeemResponse) {
                self.handler = handler
            }
            func get(url: URL) async throws -> PairingHTTPResponse {
                struct Probe: Encodable { var apiVersion: Int }
                return try PairingHTTPResponse(
                    status: 200,
                    body: JSONEncoder().encode(Probe(apiVersion: APIContract.version)),
                )
            }
            func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
                posts += 1
                let response = try handler(body)
                return try PairingHTTPResponse(status: 200, body: JSONEncoder().encode(response))
            }
        }
        let client = CountingClient { body in
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
        let receiptURL = PairingService.receiptURL(in: joinerDir)
        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
        await #expect(throws: PairingError.self) {
            try await PairingService.join(
                request: PairingJoinRequest(qrPayload: issued.qrPayload),
                dataDir: joinerDir,
                hostId: joinerId,
                client: client,
            )
        }
        #expect(client.posts == 1)
        #expect(try offers.load()?.consumedAt != nil)
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
        try FileManager.default.removeItem(at: receiptURL)
        let result = try await PairingService.join(
            request: PairingJoinRequest(qrPayload: issued.qrPayload),
            dataDir: joinerDir,
            hostId: joinerId,
            client: client,
        )
        #expect(client.posts == 1)
        #expect(result.peerHostId == issuerId)
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.peerHostId == issuerId)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: issuer.deviceFingerprint))
        #expect(!FileManager.default.fileExists(atPath: PairingService.pendingRedeemURL(in: joinerDir).path))
    }

    @Test func `join apply rejects agentPort mismatch and persists matching port`() throws {
        let issuerDir = try isolatedDir("iss-ap")
        let joinerDir = try isolatedDir("join-ap")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.168.0.9",
            port: 7_777,
            agentPort: 9_123,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        var honest = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        honest.agentPort = 7_778
        #expect(throws: PairingError.self) {
            try PairingService.applyTrust(
                response: honest,
                expected: payload,
                dataDir: joinerDir,
                localHostId: joinerId,
            )
        }
        #expect(try PairingService.loadReceipt(dataDir: joinerDir) == nil)
        honest.agentPort = 9_123
        let joined = try PairingService.applyTrust(
            response: honest,
            expected: payload,
            dataDir: joinerDir,
            localHostId: joinerId,
        )
        #expect(joined.agentPort == 9_123)
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.agentPort == 9_123)
    }

    @Test func `join apply rejects expired redeem certificates`() throws {
        let issuerDir = try isolatedDir("iss-exp")
        let joinerDir = try isolatedDir("join-exp")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
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
        let honest = try honestRedeemResponse(
            issuer: issuer,
            issuerId: issuerId,
            joiner: joiner,
            joinerId: joinerId,
        )
        #expect(throws: PairingError.self) {
            try PairingService.applyTrust(
                response: honest,
                expected: payload,
                dataDir: joinerDir,
                localHostId: joinerId,
                now: Date().addingTimeInterval(20 * 365 * 24 * 3_600),
            )
        }
        #expect(try PairingService.loadReceipt(dataDir: joinerDir) == nil)
        #expect(try PeerPinStore(dataDir: joinerDir).load().isEmpty)
    }

    @Test func `legacy receipt without agentPort defaults to config`() throws {
        let json = Data(
            """
            {"peerHostId":"h","peerFingerprint":"f","caCertificatePEM":"c",\
            "caFingerprint":"cf","issuedCertificatePEM":"i","issuedFingerprint":"if",\
            "pairedAt":"2020-01-01T00:00:00Z"}
            """.utf8,
        )
        let receipt = try JSONDecoder().decode(PairingPeerReceipt.self, from: json)
        #expect(receipt.agentPort == Config.agentPort)
    }

    @Test func `restore failure is not swallowed`() throws {
        let dir = try isolatedDir("restore-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: UUID().uuidString,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let consumed = try offers.consume(code: issued.code)
        try FileManager.default.removeItem(at: offers.fileURL)
        try FileManager.default.createDirectory(at: offers.fileURL, withIntermediateDirectories: true)
        #expect(throws: PairingError.self) {
            try offers.restore(consumed)
        }
    }

    @Test func `join rejects encoded loopback before posting trust material`() async throws {
        let joinerDir = try isolatedDir("join-ssrf")
        defer { try? FileManager.default.removeItem(at: joinerDir) }
        let joinerId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        final class Probe: PairingHTTPClient, @unchecked Sendable {
            var called = false
            func get(url: URL) async throws -> PairingHTTPResponse {
                called = true
                return PairingHTTPResponse(status: 500, body: Data())
            }
            func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
                called = true
                return PairingHTTPResponse(status: 500, body: Data())
            }
        }
        let probe = Probe()
        let qr = PairingPayload(
            code: "ABCD-EFGH",
            host: "127.1",
            port: 7_777,
            hostId: UUID().uuidString,
            fingerprint: "abcd",
        ).uri
        await #expect(throws: PairingError.self) {
            try await PairingService.join(
                request: PairingJoinRequest(qrPayload: qr),
                dataDir: joinerDir,
                hostId: joinerId,
                client: probe,
            )
        }
        #expect(!probe.called)
    }

    @Test func `join rejects public host before posting trust material`() async throws {
        let joinerDir = try isolatedDir("join-wan")
        defer { try? FileManager.default.removeItem(at: joinerDir) }
        let joinerId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        final class Probe: PairingHTTPClient, @unchecked Sendable {
            var called = false
            func get(url: URL) async throws -> PairingHTTPResponse {
                called = true
                return PairingHTTPResponse(status: 500, body: Data())
            }
            func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
                called = true
                return PairingHTTPResponse(status: 500, body: Data())
            }
        }
        let probe = Probe()
        let qr = PairingPayload(
            code: "ABCD-EFGH",
            host: "8.8.8.8",
            port: 7_777,
            hostId: UUID().uuidString,
            fingerprint: "abcd",
        ).uri
        await #expect(throws: PairingError.self) {
            try await PairingService.join(
                request: PairingJoinRequest(qrPayload: qr),
                dataDir: joinerDir,
                hostId: joinerId,
                client: probe,
            )
        }
        #expect(!probe.called)
    }

    @Test func `self signed presented device cert is rejected`() throws {
        let dir = try isolatedDir()
        let joinerDir = try isolatedDir("js")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let fakePEM = try selfSignedDevicePEM(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM)
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
                        deviceCertificatePEM: fakePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
        #expect(try PeerPinStore(dataDir: dir).load().isEmpty)
    }

    @Test func `issue fails when no advertisable host exists`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let offers = PairingOfferStore(dataDir: dir)
        #expect(throws: PairingError.self) {
            try PairingService.issue(
                PairingService.IssueInput(
                    dataDir: dir,
                    hostId: UUID().uuidString,
                    advertisedHost: nil,
                    advertisedHosts: [],
                ),
                offers: offers,
            )
        }
        #expect(throws: PairingError.self) {
            try PairingService.issue(
                PairingService.IssueInput(
                    dataDir: dir,
                    hostId: UUID().uuidString,
                    advertisedHost: "127.0.0.1",
                    advertisedHosts: ["169.254.1.1"],
                ),
                offers: offers,
            )
        }
        #expect(try offers.load() == nil)
    }

    private func honestRedeemResponse(
        issuer: HomeCertificateMaterial,
        issuerId: String,
        joiner: HomeCertificateMaterial,
        joinerId: String,
        agentPort: Int = 7_778,
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
            agentPort: agentPort,
        )
    }

    private func redeemRequest(
        code: String,
        joiner: HomeCertificateMaterial,
    ) throws -> PairingRedeemRequest {
        try PairingRedeemRequest(
            code: code,
            hostId: joiner.hostId,
            csrPEM: HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM),
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
    }

    private func selfSignedDevicePEM(
        hostId: String,
        keyPEM: String,
        now: Date = Date(),
    ) throws -> String {
        let key = try Certificate.PrivateKey(pemEncoded: keyPEM)
        let name = try DistinguishedName {
            CommonName(hostId)
        }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(3_600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                SubjectAlternativeNames([
                    .uniformResourceIdentifier(DeviceTrust.deviceURI(hostId: hostId)),
                ])
            },
            issuerPrivateKey: key,
        )
        return try cert.serializeAsPEM().pemString
    }
}
