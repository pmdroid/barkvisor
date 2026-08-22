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
            AgentPlaneCertificates.presentationCertificatePEM(material: material, receipt: nil)
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
            AgentPlaneCertificates.presentationCertificatePEM(material: joiner, receipt: receipt)
                == issued.certificatePEM,
        )
        let trusts = AgentPlaneCertificates.trustCertificatePEMs(material: joiner, receipt: receipt)
        #expect(trusts.count == 2)
        #expect(trusts[0] == joiner.caCertificatePEM)
        #expect(trusts[1] == issuer.caCertificatePEM)
    }

    @Test func `issued cert for a different key is not presented`() throws {
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
        #expect(
            AgentPlaneCertificates.presentationCertificatePEM(material: joiner, receipt: receipt)
                == joiner.deviceCertificatePEM,
        )
    }

    @Test func `home ca rotation keeps device key so issued pairing cert still presents`() throws {
        let issuerDir = try isolatedDir()
        let joinerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let now = Date()
        let future = now.addingTimeInterval(2 * 24 * 60 * 60)
        let issuer = try HomeCAService.loadOrCreate(
            dataDir: issuerDir,
            hostId: UUID().uuidString,
        )
        let joinerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(
            dataDir: joinerDir,
            hostId: joinerId,
            now: future,
        )
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: joinerId,
            csrPEM: csr,
            material: issuer,
        )
        let receipt = PairingPeerReceipt(
            peerHostId: issuer.hostId,
            peerFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            pairedAt: "2026-08-14T00:00:00Z",
        )
        #expect(
            AgentPlaneCertificates.presentationCertificatePEM(material: joiner, receipt: receipt)
                == issued.certificatePEM,
        )

        let rotated = try HomeCAService.loadOrCreate(
            dataDir: joinerDir,
            hostId: joinerId,
            now: now,
        )
        #expect(rotated.caFingerprint != joiner.caFingerprint)
        #expect(rotated.deviceKeyPEM == joiner.deviceKeyPEM)
        #expect(
            AgentPlaneCertificates.presentationCertificatePEM(material: rotated, receipt: receipt)
                == issued.certificatePEM,
        )
    }
}
