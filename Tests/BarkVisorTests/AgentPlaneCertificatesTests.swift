import Foundation
import Testing
@testable import BarkVisorCore

@Suite("AgentPlaneCertificates")
struct AgentPlaneCertificatesTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-plane-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `unpaired presentation is the local device cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        #expect(
            try AgentPlaneCertificates.presentationCertificatePEM(material: material, receipt: nil)
                == material.deviceCertificatePEM,
        )
        #expect(
            AgentPlaneCertificates.trustCertificatePEMs(material: material, receipt: nil)
                == [material.caCertificatePEM],
        )
    }

    @Test func `paired joiner presents issued cert and trusts issuer ca`() throws {
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
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: joinerId,
            csrPEM: csr,
            material: issuer,
        )
        let receipt = PairingPeerReceipt(
            peerHostId: issuerId,
            peerFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            pairedAt: "2026-08-14T00:00:00Z",
        )
        #expect(
            try AgentPlaneCertificates.presentationCertificatePEM(material: joiner, receipt: receipt)
                == issued.certificatePEM,
        )
        let trusts = AgentPlaneCertificates.trustCertificatePEMs(material: joiner, receipt: receipt)
        #expect(trusts.count == 2)
        #expect(trusts[0] == joiner.caCertificatePEM)
        #expect(trusts[1] == issuer.caCertificatePEM)
    }

    @Test func `issued cert for a different key is rejected`() throws {
        let issuerDir = try isolatedDir()
        let joinerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: UUID().uuidString)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        // Issue against a freshly generated key, not the joiner's device.key.
        let issued = try HomeCAService.issueDeviceCert(hostId: joiner.hostId, material: issuer)
        let receipt = PairingPeerReceipt(
            peerHostId: issuer.hostId,
            peerFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            pairedAt: "2026-08-14T00:00:00Z",
        )
        #expect(throws: AgentPlaneCertificates.PresentationError.self) {
            try AgentPlaneCertificates.presentationCertificatePEM(material: joiner, receipt: receipt)
        }
    }

    @Test func `device renewal preserves the pairing certificate key`() throws {
        let issuerDir = try isolatedDir()
        let joinerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let pairedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId, now: pairedAt)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId, now: pairedAt)
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: joinerId,
            csrPEM: csr,
            material: issuer,
            now: pairedAt,
        )
        let receipt = PairingPeerReceipt(
            peerHostId: issuerId,
            peerFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            pairedAt: "2020-09-13T12:26:40Z",
        )
        let renewed = try HomeCAService.loadOrCreate(
            dataDir: joinerDir,
            hostId: joinerId,
            now: pairedAt.addingTimeInterval(HomeCAService.deviceValidity - 25 * 24 * 60 * 60),
        )
        #expect(renewed.deviceKeyPEM == joiner.deviceKeyPEM)
        #expect(try AgentPlaneCertificates.presentationCertificatePEM(material: renewed, receipt: receipt)
            == issued.certificatePEM)
    }
}
