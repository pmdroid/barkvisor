import Foundation
import Testing
import X509
@testable import BarkVisorCore

@Suite("HomeCAService")
struct HomeCAServiceTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "home-ca-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `creates ca and device cert and reuses them`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString

        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        #expect(first == second)
        #expect(first.hostId == hostId)
        #expect(!first.deviceFingerprint.isEmpty)
        #expect(first.deviceFingerprint != first.caFingerprint)

        let caKeyAttrs = try FileManager.default.attributesOfItem(
            atPath: HomeCAService.caDirectory(in: dir)
                .appendingPathComponent(HomeCAService.caKeyFileName).path,
        )
        let deviceKeyAttrs = try FileManager.default.attributesOfItem(
            atPath: HomeCAService.agentDirectory(in: dir)
                .appendingPathComponent(HomeCAService.deviceKeyFileName).path,
        )
        let caPerms = (caKeyAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let devicePerms = (deviceKeyAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(caPerms & 0o777 == 0o600)
        #expect(devicePerms & 0o777 == 0o600)
    }

    @Test func `device cert san is barkvisor device uri`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let cert = try Certificate(pemEncoded: material.deviceCertificatePEM)
        #expect(DeviceTrust.hostId(from: cert) == hostId)
        #expect(DeviceTrust.deviceURI(hostId: hostId) == "barkvisor://device/\(hostId)")
    }

    @Test func `issueDeviceCert signs a second host without replacing local device`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let localId = UUID().uuidString
        let peerId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: localId)
        let issued = try HomeCAService.issueDeviceCert(hostId: peerId, dataDir: dir)
        #expect(issued.hostId == peerId)
        #expect(issued.privateKeyPEM != nil)
        #expect(issued.fingerprint != material.deviceFingerprint)

        let stillLocal = try HomeCAService.loadOrCreate(dataDir: dir, hostId: localId)
        #expect(stillLocal.deviceFingerprint == material.deviceFingerprint)

        let peerCert = try Certificate(pemEncoded: issued.certificatePEM)
        let ca = try Certificate(pemEncoded: material.caCertificatePEM)
        #expect(DeviceTrust.isIssuedByHomeCA(leaf: peerCert, ca: ca))
        #expect(DeviceTrust.hostId(from: peerCert) == peerId)
    }

    @Test func `issueDeviceCert rejects invalid csr`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        #expect(throws: HomeCAError.self) {
            try HomeCAService.issueDeviceCert(
                hostId: UUID().uuidString,
                csrPEM: "not-a-csr",
                material: material,
            )
        }
    }

    @Test func `distinct data dirs get distinct ca material`() throws {
        let a = try isolatedDir()
        let b = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let host = UUID().uuidString
        let left = try HomeCAService.loadOrCreate(dataDir: a, hostId: host)
        let right = try HomeCAService.loadOrCreate(dataDir: b, hostId: host)
        #expect(left.caFingerprint != right.caFingerprint)
        #expect(left.deviceFingerprint != right.deviceFingerprint)
    }
}
