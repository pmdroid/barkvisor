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
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
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
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
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
                advertisedHost: "192.0.2.8",
                advertisedHosts: ["192.0.2.8"],
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
