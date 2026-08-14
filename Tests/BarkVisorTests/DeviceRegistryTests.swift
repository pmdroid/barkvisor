import Foundation
import Testing
@testable import BarkVisorCore

@Suite("DeviceRegistry (PAS-34)")
struct DeviceRegistryTests {
    private func isolatedDir(_ label: String = "devices") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `upsert persists 0600 and replaces same host`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(
            hostId: "peer-a",
            fingerprint: "ABCdef",
            agentHost: "192.168.10.4",
            agentPort: 7_778,
        )
        #expect(try store.record(forHostId: "peer-a")?.fingerprint == "abcdef")
        #expect(try store.record(forHostId: "peer-a")?.agentHost == "192.168.10.4")

        try store.upsert(
            hostId: "peer-a",
            fingerprint: "ffff",
            agentHost: "10.0.0.8",
            agentPort: 7_779,
        )
        #expect(try store.load().count == 1)
        #expect(try store.record(forHostId: "peer-a")?.agentPort == 7_779)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }

    @Test func `public agent host is stored without address`() throws {
        let dir = try isolatedDir("public")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(
            hostId: "peer-b",
            fingerprint: "aa",
            agentHost: "8.8.8.8",
            agentPort: 7_778,
        )
        #expect(try store.record(forHostId: "peer-b")?.agentHost == nil)

        try store.upsert(
            hostId: "peer-c",
            fingerprint: "bb",
            agentHost: "evil.example.com",
            agentPort: 7_778,
        )
        #expect(try store.record(forHostId: "peer-c")?.agentHost == nil)
    }

    @Test func `list always includes self without network or sqlite`() throws {
        let dir = try isolatedDir("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let listed = HomeDeviceDirectory.list(
            dataDir: dir,
            hostId: hostId,
            displayName: "this-device",
        )
        #expect(listed.devices.count == 1)
        #expect(listed.devices[0].hostId == hostId)
        #expect(listed.devices[0].role == "self")
        #expect(listed.devices[0].displayName == "this-device")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("db.sqlite").path))
    }

    @Test func `list returns self when registry is corrupt`() throws {
        let dir = try isolatedDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: "peer", fingerprint: "aa", agentHost: "192.168.0.9")
        try Data("{".utf8).write(to: store.fileURL, options: [.atomic])
        let hostId = UUID().uuidString
        let listed = HomeDeviceDirectory.list(dataDir: dir, hostId: hostId)
        #expect(listed.devices.map(\.hostId) == [hostId])
        #expect(listed.devices[0].role == "self")
        #expect(throws: DeviceRegistryError.self) {
            try store.load()
        }
    }

    @Test func `pairing redeem and join write both registries`() async throws {
        let issuerDir = try isolatedDir("iss")
        let joinerDir = try isolatedDir("join")
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
                advertisedHost: "192.168.0.20",
                advertisedHosts: ["192.168.0.20"],
            ),
            offers: offers,
        )
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let request = PairingRedeemRequest(
            code: issued.code,
            hostId: joinerId,
            csrPEM: csr,
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
            agentHost: "10.0.0.14",
            agentPort: 7_778,
        )
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir, issuerHostId: issuerId, request: request,
            ),
            offers: offers,
        )
        let issuerRow = try #require(try DeviceRegistry(dataDir: issuerDir).record(forHostId: joinerId))
        #expect(issuerRow.agentHost == "10.0.0.14")
        #expect(issuerRow.fingerprint == joiner.deviceFingerprint)

        let payload = try PairingPayload.parse(issued.qrPayload)
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir, issuerHostId: issuerId, request: request,
            ),
            offers: offers,
        )
        _ = try await PairingService.applyTrust(
            response: remote,
            expected: payload,
            dataDir: joinerDir,
            localHostId: joinerId,
        )
        let joinerRow = try #require(try DeviceRegistry(dataDir: joinerDir).record(forHostId: issuerId))
        #expect(joinerRow.agentHost == "192.168.0.20")
        #expect(joinerRow.fingerprint == issuer.deviceFingerprint)

        let issuerList = HomeDeviceDirectory.list(dataDir: issuerDir, hostId: issuerId)
        #expect(issuerList.devices.map(\.role) == ["self", "member"])
        #expect(issuerList.devices.contains { $0.hostId == joinerId && $0.role == "member" })
    }
}
