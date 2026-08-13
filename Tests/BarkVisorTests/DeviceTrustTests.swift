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
}
