import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Home device health (PAS-52)")
struct HomeDeviceHealthTests {
    private func isolatedDir(_ label: String = "health") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func facts(
        name: String,
        cpuCount: Int = 2,
        running: Int = 1,
        failed: Int = 0,
    ) -> HomeDeviceLiveFacts {
        HomeDeviceLiveFacts(
            displayName: name,
            collectedAt: "2026-08-14T00:00:00Z",
            platform: HomeDevicePlatformSummary(os: "linux", arch: "arm64"),
            resources: HomeDeviceResourceSummary(
                cpuCount: cpuCount,
                memoryTotalMB: 4_096,
                memoryUsedMB: 1_024,
                cpuLoadPercent: 12.5,
            ),
            workloadCount: running + failed,
            healthCounts: ["running": running, "failed": failed],
        )
    }

    @Test func `self is always ok when every member is unreachable`() throws {
        let selfId = UUID().uuidString
        let peerId = UUID().uuidString
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: selfId, role: "self", displayName: "this-device"),
            HomeDevice(
                hostId: peerId,
                role: "member",
                agentHost: "192.168.0.9",
                pairedAt: "2026-08-14T00:00:00Z",
            ),
        ])
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: facts(name: "this-device", cpuCount: 2, running: 3),
            members: [peerId: .unreachable("Device is unreachable")],
        )
        #expect(report.devices.count == 2)
        let selfRow = try #require(report.devices.first { $0.role == "self" })
        #expect(selfRow.hostId == selfId)
        #expect(selfRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(selfRow.resources?.cpuCount == 2)
        #expect(selfRow.workloadCount == 3)
        let peer = try #require(report.devices.first { $0.hostId == peerId })
        #expect(peer.reachability == HomeDeviceHealthAggregator.unreachable)
        #expect(peer.resources == nil)
        #expect(peer.features == nil)
        #expect(peer.workloadCount == nil)
        #expect(peer.healthCounts == nil)
        #expect(report.totals.devices == 2)
        #expect(report.totals.reachable == 1)
        #expect(report.totals.unreachable == 1)
        #expect(report.totals.workloadCount == 3)
        #expect(report.totals.healthCounts["running"] == 3)
    }

    @Test func `reachable member health is summed; unreachable is not`() {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "a"),
            HomeDevice(hostId: "ok-peer", role: "member", agentHost: "10.0.0.2"),
            HomeDevice(hostId: "down-peer", role: "member", agentHost: "10.0.0.3"),
        ])
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: facts(name: "a", cpuCount: 2, running: 1, failed: 1),
            members: [
                "ok-peer": .ok(facts(name: "b", cpuCount: 2, running: 2, failed: 0)),
                "down-peer": .unreachable("peer down"),
            ],
        )
        #expect(report.totals.reachable == 2)
        #expect(report.totals.unreachable == 1)
        #expect(report.totals.workloadCount == 4)
        #expect(report.totals.healthCounts["running"] == 3)
        #expect(report.totals.healthCounts["failed"] == 1)
    }

    @Test func `corrupt registry still reports this Device`() throws {
        let dir = try isolatedDir("corrupt-health")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: "peer", fingerprint: "aa", agentHost: "192.168.0.9")
        try Data("{".utf8).write(to: store.fileURL, options: [.atomic])
        let hostId = UUID().uuidString
        let listed = HomeDeviceDirectory.list(dataDir: dir, hostId: hostId, displayName: "solo")
        #expect(listed.devices.map(\.hostId) == [hostId])
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: facts(name: "solo", cpuCount: 2),
            members: [:],
        )
        #expect(report.devices.count == 1)
        #expect(report.devices[0].role == "self")
        #expect(report.devices[0].reachability == HomeDeviceHealthAggregator.ok)
        #expect(report.totals.unreachable == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("db.sqlite").path))
    }

    @Test func `facts project inventory without using host cpuCount`() throws {
        let inventory = HostInventory(
            hostId: "host-1",
            displayName: "desk",
            agent: AgentInfo(version: "test"),
            platform: PlatformInfo(
                os: "macos", osVersion: "15.0", arch: "arm64", hostname: "desk",
            ),
            resources: ResourcesInfo(
                cpuCount: 2, memoryTotalMB: 8_192, memoryUsedMB: 2_048, cpuLoadPercent: 4,
            ),
            storage: [],
            networking: NetworkingInfo(
                interfaces: [],
                addresses: DeviceReachabilityAddresses(
                    lan: ["192.168.0.8"],
                    tailnet: ["100.64.1.2"],
                ),
            ),
            virtualization: VirtualizationInfo(
                accelerator: "hvf",
                qemuCPUModel: "host",
                defaultGuestArch: "arm64",
                features: VirtualizationFeatures(
                    bridgedNetworking: false,
                    managedBridgeDaemon: false,
                    usbPassthrough: false,
                    inAppUpdate: false,
                    kvmDevice: false,
                    qemuBridgeHelper: false,
                ),
            ),
            guestTypes: [],
            collectedAt: "2026-08-14T00:00:00Z",
        )
        let summary = WorkloadHealthSummary(
            counts: ["running": 1, "stopped": 2],
            items: [
                WorkloadHealthSummaryItem(id: "vm-1", name: "one", health: .running),
                WorkloadHealthSummaryItem(id: "vm-2", name: "two", health: .stopped),
                WorkloadHealthSummaryItem(id: "vm-3", name: "three", health: .stopped),
            ],
            updatedAt: "2026-08-14T00:00:00Z",
        )
        let encoded = try JSONEncoder().encode(inventory)
        let decoded = try HomeDeviceHealthAggregator.decodeInventory(encoded)
        let live = HomeDeviceHealthAggregator.facts(from: decoded, summary: summary)
        #expect(live.displayName == "desk")
        #expect(live.platform?.arch == "arm64")
        #expect(live.resources?.cpuCount == 2)
        #expect(live.features?.kvmDevice == false)
        #expect(live.features?.bridgedNetworking == false)
        #expect(live.features?.usbPassthrough == false)
        #expect(live.workloadCount == 3)
        #expect(live.healthCounts?["stopped"] == 2)
        let inventoryOnly = HomeDeviceHealthAggregator.facts(from: decoded, summary: nil)
        #expect(inventoryOnly.workloadCount == nil)
        #expect(inventoryOnly.healthCounts == nil)
        #expect(live.addresses?.lan == ["192.168.0.8"])
        #expect(live.addresses?.tailnet == ["100.64.1.2"])
    }

    @Test func `unreachable member omits live addresses`() {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "a"),
            HomeDevice(hostId: "down-peer", role: "member", agentHost: "10.0.0.3"),
        ])
        let local = HomeDeviceLiveFacts(
            displayName: "a",
            addresses: DeviceReachabilityAddresses(lan: ["10.0.0.2"], tailnet: []),
        )
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: local,
            members: ["down-peer": .unreachable("peer down")],
        )
        #expect(report.devices.first { $0.role == "self" }?.addresses?.lan == ["10.0.0.2"])
        #expect(report.devices.first { $0.hostId == "down-peer" }?.addresses == nil)
    }

    @Test func `reachable device with unknown health is not counted as zero workloads`() {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "a"),
            HomeDevice(hostId: "ok-peer", role: "member", agentHost: "10.0.0.2"),
        ])
        let inventoryOnly = HomeDeviceLiveFacts(
            displayName: "b",
            collectedAt: "2026-08-14T00:00:00Z",
            platform: HomeDevicePlatformSummary(os: "linux", arch: "arm64"),
            resources: HomeDeviceResourceSummary(
                cpuCount: 2, memoryTotalMB: 4_096, memoryUsedMB: 1_024, cpuLoadPercent: 8,
            ),
            workloadCount: nil,
            healthCounts: nil,
        )
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: facts(name: "a", cpuCount: 2, running: 3),
            members: ["ok-peer": .ok(inventoryOnly)],
        )
        let peer = report.devices.first { $0.hostId == "ok-peer" }
        #expect(peer?.reachability == HomeDeviceHealthAggregator.ok)
        #expect(peer?.workloadCount == nil)
        #expect(peer?.healthCounts == nil)
        #expect(report.totals.reachable == 2)
        #expect(report.totals.workloadCount == nil)
        #expect(report.totals.healthCounts["running"] == 3)
    }

    @Test func `missing member result is unreachable not invented live data`() {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self"),
            HomeDevice(hostId: "ghost", role: "member"),
        ])
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: facts(name: "self", cpuCount: 2),
            members: [:],
        )
        let ghost = report.devices.first { $0.hostId == "ghost" }
        #expect(ghost?.reachability == HomeDeviceHealthAggregator.unreachable)
        #expect(ghost?.resources == nil)
        #expect(ghost?.features == nil)
        #expect(ghost?.reachabilityError == "Device is unreachable")
    }

    @Test func `freeMemoryMB rejects invalid metrics and saturates instead of overflowing`() {
        let missing = HomeDeviceResourceSummary(memoryTotalMB: 4_096, memoryUsedMB: nil)
        #expect(missing.freeMemoryMB == nil)

        let negativeUsed = HomeDeviceResourceSummary(memoryTotalMB: Int.max, memoryUsedMB: -1)
        #expect(negativeUsed.freeMemoryMB == nil)

        let negativeTotal = HomeDeviceResourceSummary(memoryTotalMB: -8, memoryUsedMB: 1)
        #expect(negativeTotal.freeMemoryMB == nil)

        let overused = HomeDeviceResourceSummary(memoryTotalMB: 1_024, memoryUsedMB: 4_096)
        #expect(overused.freeMemoryMB == 0)

        let normal = HomeDeviceResourceSummary(memoryTotalMB: 4_096, memoryUsedMB: 1_024)
        #expect(normal.freeMemoryMB == 3_072)

        let maxed = HomeDeviceResourceSummary(memoryTotalMB: Int.max, memoryUsedMB: 0)
        #expect(maxed.freeMemoryMB == Int.max)
    }
}
