import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Pairing recovery (PAS-77)")
struct PairingRecoveryTests {
    private func isolatedDir(_ label: String = "repair") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rotateDeviceCert(dataDir: URL, hostId: String) throws -> HomeCertificateMaterial {
        let agent = HomeCAService.agentDirectory(in: dataDir)
        try FileManager.default.removeItem(
            at: agent.appendingPathComponent(HomeCAService.deviceCertificateFileName),
        )
        try FileManager.default.removeItem(
            at: agent.appendingPathComponent(HomeCAService.deviceKeyFileName),
        )
        return try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
    }

    private func redeemRequest(
        code: String,
        joiner: HomeCertificateMaterial,
        agentHost: String = "10.0.0.14",
    ) throws -> PairingRedeemRequest {
        try PairingRedeemRequest(
            code: code,
            hostId: joiner.hostId,
            csrPEM: HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM),
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
            agentHost: agentHost,
            agentPort: 7_778,
        )
    }

    private func issueCode(dataDir: URL, hostId: String, host: String = "192.168.0.20") throws
        -> PairingIssueResponse {
        try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dataDir,
                hostId: hostId,
                advertisedHost: host,
                advertisedHosts: [host],
            ),
            offers: PairingOfferStore(dataDir: dataDir),
        )
    }

    @Test func `new pairing code re-pins same hostId after cert rotation`() throws {
        let issuerDir = try isolatedDir("iss")
        let joinerDir = try isolatedDir("join")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let persistedHost = HostIdentity.loadOrCreate(dataDir: joinerDir)
        let joinerId = persistedHost.uuidString
        let sqlite = joinerDir.appendingPathComponent("db.sqlite")
        try Data("local-runtime".utf8).write(to: sqlite)
        let firstJoiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let firstFP = firstJoiner.deviceFingerprint
        let offers = PairingOfferStore(dataDir: issuerDir)
        let first = try issueCode(dataDir: issuerDir, hostId: issuerId)
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: redeemRequest(code: first.code, joiner: firstJoiner),
            ),
            offers: offers,
        )
        #expect(try PeerPinStore(dataDir: issuerDir).pin(forHostId: joinerId)?.fingerprint == firstFP)
        #expect(try DeviceRegistry(dataDir: issuerDir).record(forHostId: joinerId)?.fingerprint == firstFP)

        let rotated = try rotateDeviceCert(dataDir: joinerDir, hostId: joinerId)
        #expect(rotated.deviceFingerprint != firstFP)
        #expect(rotated.hostId == joinerId)

        let second = try issueCode(dataDir: issuerDir, hostId: issuerId)
        #expect(second.code != first.code)
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: redeemRequest(code: second.code, joiner: rotated, agentHost: "10.0.0.99"),
            ),
            offers: offers,
        )

        let pins = try PeerPinStore(dataDir: issuerDir).load()
        #expect(pins.count == 1)
        #expect(pins[0].hostId == joinerId)
        #expect(pins[0].fingerprint == rotated.deviceFingerprint)
        #expect(try PeerPinStore(dataDir: issuerDir).contains(fingerprint: firstFP) == false)

        let row = try #require(try DeviceRegistry(dataDir: issuerDir).record(forHostId: joinerId))
        #expect(row.fingerprint == rotated.deviceFingerprint)
        #expect(row.agentHost == "10.0.0.99")
        #expect(try DeviceRegistry(dataDir: issuerDir).load().count == 1)

        let listed = HomeDeviceDirectory.list(dataDir: issuerDir, hostId: issuerId)
        #expect(listed.devices.filter { $0.role == "member" }.map(\.hostId) == [joinerId])

        #expect(HostIdentity.loadOrCreate(dataDir: joinerDir) == persistedHost)
        #expect(try String(contentsOf: sqlite, encoding: .utf8) == "local-runtime")
        #expect(!FileManager.default.fileExists(atPath: issuerDir.appendingPathComponent("db.sqlite").path))
    }

    @Test func `consumed code with a new fingerprint still needs a fresh code`() throws {
        let issuerDir = try isolatedDir("iss-used")
        let joinerDir = try isolatedDir("join-used")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let firstJoiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let issued = try issueCode(dataDir: issuerDir, hostId: issuerId)
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: redeemRequest(code: issued.code, joiner: firstJoiner),
            ),
            offers: offers,
        )
        let rotated = try rotateDeviceCert(dataDir: joinerDir, hostId: joinerId)
        #expect(throws: PairingError.expiredOrUsed) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: issuerDir,
                    issuerHostId: issuerId,
                    request: redeemRequest(code: issued.code, joiner: rotated),
                ),
                offers: offers,
            )
        }
        #expect(
            try PeerPinStore(dataDir: issuerDir).pin(forHostId: joinerId)?.fingerprint
                == firstJoiner.deviceFingerprint,
        )
    }

    @Test func `applyTrust re-pair replaces receipt and leaves local runtime`() async throws {
        let issuerDir = try isolatedDir("iss-apply")
        let joinerDir = try isolatedDir("join-apply")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let persistedHost = HostIdentity.loadOrCreate(dataDir: joinerDir)
        let sqlite = joinerDir.appendingPathComponent("db.sqlite")
        try Data("local-runtime".utf8).write(to: sqlite)

        let firstIssuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let first = try issueCode(dataDir: issuerDir, hostId: issuerId, host: "192.168.0.20")
        let firstRemote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: redeemRequest(code: first.code, joiner: joiner),
            ),
            offers: offers,
        )
        _ = try await PairingService.applyTrust(
            response: firstRemote,
            expected: PairingPayload.parse(first.qrPayload),
            dataDir: joinerDir,
            localHostId: joinerId,
        )
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.peerFingerprint == firstIssuer.deviceFingerprint)

        let rotatedIssuer = try rotateDeviceCert(dataDir: issuerDir, hostId: issuerId)
        #expect(rotatedIssuer.deviceFingerprint != firstIssuer.deviceFingerprint)
        let second = try issueCode(dataDir: issuerDir, hostId: issuerId, host: "192.168.0.21")
        let secondRemote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: redeemRequest(code: second.code, joiner: joiner),
            ),
            offers: offers,
        )
        #expect(secondRemote.deviceFingerprint == rotatedIssuer.deviceFingerprint)
        _ = try await PairingService.applyTrust(
            response: secondRemote,
            expected: PairingPayload.parse(second.qrPayload),
            dataDir: joinerDir,
            localHostId: joinerId,
        )

        let receipt = try #require(try PairingService.loadReceipt(dataDir: joinerDir))
        #expect(receipt.peerHostId == issuerId)
        #expect(receipt.peerFingerprint == rotatedIssuer.deviceFingerprint)
        #expect(try PeerPinStore(dataDir: joinerDir).pin(forHostId: issuerId)?.fingerprint
            == rotatedIssuer.deviceFingerprint)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: firstIssuer.deviceFingerprint) == false)
        let row = try #require(try DeviceRegistry(dataDir: joinerDir).record(forHostId: issuerId))
        #expect(row.fingerprint == rotatedIssuer.deviceFingerprint)
        #expect(row.agentHost == "192.168.0.21")

        #expect(HostIdentity.loadOrCreate(dataDir: joinerDir) == persistedHost)
        #expect(try String(contentsOf: sqlite, encoding: .utf8) == "local-runtime")
        #expect(joiner.hostId == joinerId)
    }
}
