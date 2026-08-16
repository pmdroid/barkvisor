import Crypto
import Foundation
import Testing
import X509
@testable import BarkVisorCore

@Suite("DeviceTrust")
struct DeviceTrustTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "device-trust-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `accepts home ca issued cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let peerId = UUID().uuidString
        let issued = try HomeCAService.issueDeviceCert(hostId: peerId, dataDir: dir)

        let decision = DeviceTrust.evaluate(
            leafPEM: issued.certificatePEM,
            homeCAPEM: local.caCertificatePEM,
            pins: [],
        )
        #expect(decision == .accepted(hostId: peerId, source: .homeCA))
    }

    @Test func `rejects foreign ca cert without pin`() throws {
        let a = try isolatedDir()
        let b = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let local = try HomeCAService.loadOrCreate(dataDir: a, hostId: UUID().uuidString)
        let foreign = try HomeCAService.loadOrCreate(dataDir: b, hostId: UUID().uuidString)

        let decision = DeviceTrust.evaluate(
            leafPEM: foreign.deviceCertificatePEM,
            homeCAPEM: local.caCertificatePEM,
            pins: [],
        )
        #expect(decision == .rejected(.untrusted))
    }

    @Test func `accepts pairwise pinned foreign cert`() throws {
        let a = try isolatedDir()
        let b = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let local = try HomeCAService.loadOrCreate(dataDir: a, hostId: UUID().uuidString)
        let foreignId = UUID().uuidString
        let foreign = try HomeCAService.loadOrCreate(dataDir: b, hostId: foreignId)
        let pin = PeerPin(
            hostId: foreignId,
            fingerprint: foreign.deviceFingerprint,
            pinnedAt: iso8601.string(from: Date()),
        )

        let decision = DeviceTrust.evaluate(
            leafPEM: foreign.deviceCertificatePEM,
            homeCAPEM: local.caCertificatePEM,
            pins: [pin],
        )
        #expect(decision == .accepted(hostId: foreignId, source: .pinned))
    }

    @Test func `rejects expired cert even if pinned`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: UUID().uuidString,
            material: material,
            now: Date().addingTimeInterval(-10_000),
            validity: 60,
        )
        let pin = PeerPin(
            hostId: issued.hostId,
            fingerprint: issued.fingerprint,
            pinnedAt: iso8601.string(from: Date()),
        )
        let decision = DeviceTrust.evaluate(
            leafPEM: issued.certificatePEM,
            homeCAPEM: material.caCertificatePEM,
            pins: [pin],
            now: Date(),
        )
        #expect(decision == .rejected(.expired))
    }

    @Test func `rejects garbage pem`() {
        let decision = DeviceTrust.evaluate(leafPEM: "nope", homeCAPEM: "also-nope", pins: [])
        #expect(decision == .rejected(.invalidPEM))
    }

    @Test func `rejects pinned cert without device san`() throws {
        let now = Date()
        let (ca, caKey, caPEM) = try mintCA(now: now)
        let leaf = try mintLeaf(hostId: nil, issuer: (ca, caKey), now: now)
        let pin = try PeerPin(
            hostId: "claimed-host",
            fingerprint: DeviceTrust.fingerprint(certificate: leaf),
            pinnedAt: iso8601.string(from: now),
        )
        let decision = DeviceTrust.evaluate(
            leaf: leaf,
            homeCAPEM: caPEM,
            pins: [pin],
            now: now,
        )
        #expect(decision == .rejected(.missingDeviceSAN))
    }

    @Test func `rejects leaf when home ca is expired`() throws {
        let now = Date()
        let (ca, caKey, caPEM) = try mintCA(now: now, notBefore: -200, notAfter: -100)
        let leaf = try mintLeaf(
            hostId: UUID().uuidString,
            issuer: (ca, caKey),
            now: now,
            notBefore: -150,
            notAfter: 3_600,
        )
        let decision = DeviceTrust.evaluate(leaf: leaf, homeCAPEM: caPEM, pins: [], now: now)
        #expect(decision == .rejected(.expired))
    }

    @Test func `rejects leaf when home ca is not yet valid`() throws {
        let now = Date()
        let (ca, caKey, caPEM) = try mintCA(now: now, notBefore: 100, notAfter: 10_000)
        let leaf = try mintLeaf(
            hostId: UUID().uuidString,
            issuer: (ca, caKey),
            now: now,
        )
        let decision = DeviceTrust.evaluate(leaf: leaf, homeCAPEM: caPEM, pins: [], now: now)
        #expect(decision == .rejected(.expired))
    }

    private func mintCA(
        now: Date,
        notBefore: TimeInterval = -60,
        notAfter: TimeInterval = 365 * 24 * 3_600,
    ) throws -> (Certificate, Certificate.PrivateKey, String) {
        let privateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName {
            CommonName("Test Home CA")
        }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(1),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(notBefore),
            notValidAfter: now.addingTimeInterval(notAfter),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: privateKey,
        )
        return try (cert, privateKey, cert.serializeAsPEM().pemString)
    }

    private func mintLeaf(
        hostId: String?,
        issuer: (Certificate, Certificate.PrivateKey),
        now: Date,
        notBefore: TimeInterval = -60,
        notAfter: TimeInterval = 3_600,
    ) throws -> Certificate {
        let privateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName {
            CommonName(hostId ?? "no-san")
        }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(notBefore),
            notValidAfter: now.addingTimeInterval(notAfter),
            issuer: issuer.0.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                if let hostId {
                    SubjectAlternativeNames([
                        .uniformResourceIdentifier(DeviceTrust.deviceURI(hostId: hostId)),
                    ])
                }
            },
            issuerPrivateKey: issuer.1,
        )
    }
}
