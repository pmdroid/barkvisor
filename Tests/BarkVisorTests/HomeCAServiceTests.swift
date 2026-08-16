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

    @Test func `corrupt ca key does not remint home ca`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let keyURL = HomeCAService.caDirectory(in: dir)
            .appendingPathComponent(HomeCAService.caKeyFileName)
        try Data("not-a-key".utf8).write(to: keyURL, options: [.atomic])

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedCAFingerprint(in: dir) == first.caFingerprint)
    }

    @Test func `mismatched ca key does not remint home ca`() throws {
        let dir = try isolatedDir()
        let otherDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let other = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: UUID().uuidString)
        let keyURL = HomeCAService.caDirectory(in: dir)
            .appendingPathComponent(HomeCAService.caKeyFileName)
        try Data(other.caKeyPEM.utf8).write(to: keyURL, options: [.atomic])

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedCAFingerprint(in: dir) == first.caFingerprint)
    }

    @Test func `partial ca files do not remint home ca`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        try FileManager.default.removeItem(
            at: HomeCAService.caDirectory(in: dir)
                .appendingPathComponent(HomeCAService.caKeyFileName),
        )

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedCAFingerprint(in: dir) == first.caFingerprint)
    }

    @Test func `corrupt device key does not remint device cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let keyURL = HomeCAService.agentDirectory(in: dir)
            .appendingPathComponent(HomeCAService.deviceKeyFileName)
        try Data("not-a-key".utf8).write(to: keyURL, options: [.atomic])

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedDeviceFingerprint(in: dir) == first.deviceFingerprint)
    }

    @Test func `mismatched device key does not remint device cert`() throws {
        let dir = try isolatedDir()
        let otherDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let other = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: UUID().uuidString)
        let keyURL = HomeCAService.agentDirectory(in: dir)
            .appendingPathComponent(HomeCAService.deviceKeyFileName)
        try Data(other.deviceKeyPEM.utf8).write(to: keyURL, options: [.atomic])

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedDeviceFingerprint(in: dir) == first.deviceFingerprint)
    }

    @Test func `partial device files do not remint device cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        try FileManager.default.removeItem(
            at: HomeCAService.agentDirectory(in: dir)
                .appendingPathComponent(HomeCAService.deviceKeyFileName),
        )

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedDeviceFingerprint(in: dir) == first.deviceFingerprint)
    }

    @Test func `device cert san mismatch does not remint device cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        }
        #expect(try persistedDeviceFingerprint(in: dir) == first.deviceFingerprint)
    }

    @Test func `device cert not issued by home ca does not remint`() throws {
        let dir = try isolatedDir()
        let otherDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let other = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: first.hostId)
        let certURL = HomeCAService.agentDirectory(in: dir)
            .appendingPathComponent(HomeCAService.deviceCertificateFileName)
        let keyURL = HomeCAService.agentDirectory(in: dir)
            .appendingPathComponent(HomeCAService.deviceKeyFileName)
        try Data(other.deviceCertificatePEM.utf8).write(to: certURL, options: [.atomic])
        try Data(other.deviceKeyPEM.utf8).write(to: keyURL, options: [.atomic])

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: first.hostId)
        }
        #expect(try persistedDeviceFingerprint(in: dir) == other.deviceFingerprint)
        #expect(try persistedCAFingerprint(in: dir) == first.caFingerprint)
    }

    @Test func `expired device cert is reminted and ca is reused`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600))

        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)

        #expect(first.caFingerprint == second.caFingerprint)
        #expect(first.deviceFingerprint != second.deviceFingerprint)
        #expect(try persistedDeviceFingerprint(in: dir) == second.deviceFingerprint)

        let device = try Certificate(pemEncoded: second.deviceCertificatePEM)
        let ca = try Certificate(pemEncoded: second.caCertificatePEM)
        #expect(now <= device.notValidAfter)
        #expect(!HomeCAService.certificateNeedsRenewal(
            device,
            now: now,
            renewalWindow: HomeCAService.deviceRenewalWindow,
        ))
        #expect(DeviceTrust.isIssuedByHomeCA(leaf: device, ca: ca))
        #expect(DeviceTrust.hostId(from: device) == hostId)
    }

    @Test func `device cert near expiry is reminted`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(
            -(HomeCAService.deviceValidity - HomeCAService.deviceRenewalWindow / 2),
        )

        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)

        #expect(first.caFingerprint == second.caFingerprint)
        #expect(first.deviceFingerprint != second.deviceFingerprint)
    }

    @Test func `device cert outside renewal window is reused`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-100 * 24 * 60 * 60)

        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)

        #expect(first == second)
    }

    @Test func `not-yet-valid home ca is reminted with a new device cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let future = now.addingTimeInterval(2 * 24 * 60 * 60)

        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: future)
        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)

        #expect(first.caFingerprint != second.caFingerprint)
        #expect(first.deviceFingerprint != second.deviceFingerprint)
        let ca = try Certificate(pemEncoded: second.caCertificatePEM)
        let device = try Certificate(pemEncoded: second.deviceCertificatePEM)
        #expect(HomeCAService.isCurrentlyValid(ca, now: now))
        #expect(DeviceTrust.isIssuedByHomeCA(leaf: device, ca: ca))
        #expect(DeviceTrust.hostId(from: device) == hostId)
    }

    @Test func `pending rotation journal is applied on load`() throws {
        let dir = try isolatedDir()
        let otherDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let hostId = UUID().uuidString
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let replacement = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: hostId)

        let staging = HomeCAService.caDirectory(in: dir)
            .appendingPathComponent(HomeCAService.rotationDirectoryName)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(replacement.caCertificatePEM.utf8).write(
            to: staging.appendingPathComponent(HomeCAService.caCertificateFileName),
        )
        try Data(replacement.caKeyPEM.utf8).write(
            to: staging.appendingPathComponent(HomeCAService.caKeyFileName),
        )
        try Data("3".utf8).write(to: staging.appendingPathComponent(HomeCAService.serialFileName))
        try Data(replacement.deviceCertificatePEM.utf8).write(
            to: staging.appendingPathComponent(HomeCAService.deviceCertificateFileName),
        )
        try Data(replacement.deviceKeyPEM.utf8).write(
            to: staging.appendingPathComponent(HomeCAService.deviceKeyFileName),
        )
        try Data().write(to: staging.appendingPathComponent(HomeCAService.rotationReadyFileName))

        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        #expect(second.caFingerprint == replacement.caFingerprint)
        #expect(second.deviceFingerprint == replacement.deviceFingerprint)
        #expect(second.caFingerprint != first.caFingerprint)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func `incomplete rotation staging is discarded`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let staging = HomeCAService.caDirectory(in: dir)
            .appendingPathComponent(HomeCAService.rotationDirectoryName)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("not-ready".utf8).write(
            to: staging.appendingPathComponent(HomeCAService.caCertificateFileName),
        )

        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        #expect(second == first)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func `expired home ca is reminted with a new device cert`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.caValidity + 3_600))

        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let second = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)

        #expect(first.caFingerprint != second.caFingerprint)
        #expect(first.deviceFingerprint != second.deviceFingerprint)
        #expect(try persistedCAFingerprint(in: dir) == second.caFingerprint)
        #expect(try persistedDeviceFingerprint(in: dir) == second.deviceFingerprint)

        let ca = try Certificate(pemEncoded: second.caCertificatePEM)
        let device = try Certificate(pemEncoded: second.deviceCertificatePEM)
        #expect(now <= ca.notValidAfter)
        #expect(!HomeCAService.isExpired(ca, now: now))
        #expect(DeviceTrust.isIssuedByHomeCA(leaf: device, ca: ca))
        #expect(DeviceTrust.hostId(from: device) == hostId)

        let decision = DeviceTrust.evaluate(
            leafPEM: second.deviceCertificatePEM,
            homeCAPEM: second.caCertificatePEM,
            pins: [],
            now: now,
        )
        #expect(decision == .accepted(hostId: hostId, source: .homeCA))
    }

    @Test func `issueDeviceCert after ca expiry signs with reminted ca`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.caValidity + 3_600))
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)

        let peerId = UUID().uuidString
        let issued = try HomeCAService.issueDeviceCert(hostId: peerId, dataDir: dir, now: now)
        let reloaded = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)

        #expect(reloaded.caFingerprint != first.caFingerprint)
        #expect(reloaded.deviceFingerprint != first.deviceFingerprint)

        let ca = try Certificate(pemEncoded: reloaded.caCertificatePEM)
        let issuedCert = try Certificate(pemEncoded: issued.certificatePEM)
        #expect(DeviceTrust.isIssuedByHomeCA(leaf: issuedCert, ca: ca))
        #expect(DeviceTrust.hostId(from: issuedCert) == peerId)
    }

    @Test func `expired device cert with corrupt key still does not remint`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600))
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let keyURL = HomeCAService.agentDirectory(in: dir)
            .appendingPathComponent(HomeCAService.deviceKeyFileName)
        try Data("not-a-key".utf8).write(to: keyURL, options: [.atomic])

        #expect(throws: HomeCAError.self) {
            try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)
        }
        #expect(try persistedDeviceFingerprint(in: dir) == first.deviceFingerprint)
        #expect(try persistedCAFingerprint(in: dir) == first.caFingerprint)
    }

    private func persistedCAFingerprint(in dataDir: URL) throws -> String {
        let certPEM = try String(
            contentsOf: HomeCAService.caDirectory(in: dataDir)
                .appendingPathComponent(HomeCAService.caCertificateFileName),
            encoding: .utf8,
        )
        return try DeviceTrust.fingerprint(pem: certPEM)
    }

    private func persistedDeviceFingerprint(in dataDir: URL) throws -> String {
        let certPEM = try String(
            contentsOf: HomeCAService.agentDirectory(in: dataDir)
                .appendingPathComponent(HomeCAService.deviceCertificateFileName),
            encoding: .utf8,
        )
        return try DeviceTrust.fingerprint(pem: certPEM)
    }
}
