import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Home device membership removal")
struct HomeDeviceMembershipTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "home-device-removal-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `removal clears directory and peer pin without contacting an offline member`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let devices = DeviceRegistry(dataDir: dir)
        let pins = PeerPinStore(dataDir: dir)
        try devices.upsert(hostId: "offline-peer", fingerprint: "aabb", agentHost: "192.168.1.9")
        try pins.pin(hostId: "offline-peer", fingerprint: "aabb")

        try HomeDeviceMembership.remove(
            hostId: "offline-peer",
            localHostId: "home-device",
            dataDir: dir,
            devices: devices,
            pins: pins,
        )

        #expect(try devices.record(forHostId: "offline-peer") == nil)
        #expect(try pins.pin(forHostId: "offline-peer") == nil)
        #expect(HomeDeviceDirectory.list(dataDir: dir, hostId: "home-device").devices.map(\.hostId) == ["home-device"])

        // A repeat needs no peer and leaves the same clean state.
        try HomeDeviceMembership.remove(
            hostId: "offline-peer",
            localHostId: "home-device",
            dataDir: dir,
            devices: devices,
            pins: pins,
        )
    }

    @Test func `removal rejects the local Device and preserves membership`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let devices = DeviceRegistry(dataDir: dir)
        let pins = PeerPinStore(dataDir: dir)
        try devices.upsert(hostId: "peer", fingerprint: "aabb")
        try pins.pin(hostId: "peer", fingerprint: "aabb")

        #expect(throws: BarkVisorError.self) {
            try HomeDeviceMembership.remove(
                hostId: "home-device",
                localHostId: "home-device",
                dataDir: dir,
                devices: devices,
                pins: pins,
            )
        }
        #expect(try devices.record(forHostId: "peer") != nil)
        #expect(try pins.pin(forHostId: "peer") != nil)
    }
}
