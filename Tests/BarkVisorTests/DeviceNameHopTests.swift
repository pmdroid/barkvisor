import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Device name hop (#388)")
struct DeviceNameHopTests {
    private func isolatedDir(_ label: String = "name-hop") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `member hop path is PUT /api/system/device-name`() throws {
        #expect(
            try HomeDeviceProxy.memberAPIPath(components: ["system", "device-name"])
                == "/api/system/device-name",
        )
        let url = try HomeDeviceProxy.memberURL(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/system/device-name",
        )
        #expect(url.path == "/api/system/device-name")
        #expect(url.host == "10.0.0.8")
    }

    @Test func `PUT hop persists on the member and health shows the new name`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = UUID().uuidString
        let peerId = "peer-1"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "aa", agentHost: "10.0.0.8", agentPort: 7_778)

        let member = MemberNameStore(hostId: peerId, initialName: "desk")
        let hopPath = try HomeDeviceProxy.memberAPIPath(components: ["system", "device-name"])
        let hopURL = try HomeDeviceProxy.memberURL(
            host: "10.0.0.8",
            port: 7_778,
            path: hopPath,
        )
        let put = try await member.send(
            HomeDeviceProxyRequest(
                method: "PUT",
                url: hopURL,
                headers: [("Content-Type", "application/json")],
                body: Data(#"{"displayName":"Studio Mac"}"#.utf8),
            ),
        )
        #expect(put.status == 200)
        let named = try JSONDecoder().decode(NameBody.self, from: put.body)
        #expect(named.displayName == "Studio Mac")
        #expect(member.displayName() == "Studio Mac")

        let ctl = HomeDevicesController(
            dataDir: dir,
            hostId: selfId,
            devices: store,
            mtlsClient: member,
            localFacts: {
                HomeDeviceLiveFacts(
                    displayName: "this-device",
                    collectedAt: "2026-08-14T00:00:00Z",
                    platform: HomeDevicePlatformSummary(os: "linux", arch: "arm64"),
                    resources: HomeDeviceResourceSummary(
                        cpuCount: 2, memoryTotalMB: 4_096, memoryUsedMB: 1_024, cpuLoadPercent: 8,
                    ),
                    workloadCount: 1,
                    healthCounts: ["running": 1],
                )
            },
        )
        let outcome = await ctl.probeMember(
            HomeDevice(hostId: peerId, role: "member", displayName: "desk", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: "home-jwt",
        )
        guard case let .ok(facts) = outcome else {
            Issue.record("expected reachable member after rename, got \(outcome)")
            return
        }
        #expect(facts.displayName == "Studio Mac")

        let listed = HomeDeviceDirectory.list(
            dataDir: dir, hostId: selfId, displayName: "this-device", devices: store,
        )
        let report = await ctl.healthReport(
            listed: listed,
            local: HomeDeviceLiveFacts(
                displayName: "this-device",
                collectedAt: "2026-08-14T00:00:00Z",
                platform: HomeDevicePlatformSummary(os: "linux", arch: "arm64"),
                resources: HomeDeviceResourceSummary(
                    cpuCount: 2, memoryTotalMB: 4_096, memoryUsedMB: 1_024, cpuLoadPercent: 8,
                ),
                workloadCount: 1,
                healthCounts: ["running": 1],
            ),
            bearer: "home-jwt",
        )
        let peer = try #require(report.devices.first { $0.hostId == peerId })
        #expect(peer.displayName == "Studio Mac")
        #expect(peer.reachability == HomeDeviceHealthAggregator.ok)
    }

    @Test func `inventory and health pick up a saved name without a restart`() throws {
        let dir = try isolatedDir("name-persist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try pool.write { db in
            let saved = try DeviceNameSettings.save("Garage PC", db: db)
            #expect(saved == "Garage PC")
        }
        let stored = try pool.read { try DeviceNameSettings.resolved(from: $0, hostname: "studio.local") }
        #expect(stored == "Garage PC")

        let snap = HostInventoryService.snapshot(
            dataDir: dir,
            hostId: "host-1",
            displayName: stored,
        )
        #expect(snap.displayName == "Garage PC")
        let facts = HomeDeviceHealthAggregator.facts(from: snap)
        #expect(facts.displayName == "Garage PC")

        let report = HomeDeviceHealthAggregator.report(
            listed: HomeDeviceList(devices: [
                HomeDevice(hostId: "self", role: "self", displayName: "old-self"),
                HomeDevice(hostId: "peer", role: "member", displayName: "old-peer"),
            ]),
            local: facts,
            members: ["peer": .ok(facts)],
        )
        #expect(report.devices.first { $0.hostId == "self" }?.displayName == "Garage PC")
        #expect(report.devices.first { $0.hostId == "peer" }?.displayName == "Garage PC")
    }
}

private struct NameBody: Decodable {
    var displayName: String
}

/// Member stand-in: PUT /api/system/device-name writes the name; inventory reads it live.
private final class MemberNameStore: HomeDeviceProxyClient, @unchecked Sendable {
    private let lock = NSLock()
    private var name: String
    private let hostId: String

    init(hostId: String, initialName: String) {
        self.hostId = hostId
        name = initialName
    }

    func displayName() -> String {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    private func setName(_ value: String) {
        lock.lock()
        name = value
        lock.unlock()
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        let path = request.url.path
        if request.method == "PUT", path == "/api/system/device-name" {
            let body = try JSONDecoder().decode(NameBody.self, from: request.body ?? Data())
            let parsed = try DeviceNameSettings.parse(body.displayName)
            setName(parsed)
            let payload = try JSONEncoder().encode(["displayName": parsed, "hostname": hostId])
            return HomeDeviceProxyResponse(status: 200, body: payload)
        }
        if request.method == "GET", path == "/api/agent/inventory" {
            let current = displayName()
            let inventory = HostInventory(
                hostId: hostId,
                displayName: current,
                agent: AgentInfo(version: "test"),
                platform: PlatformInfo(
                    os: "linux", osVersion: "6.8", arch: "arm64", hostname: current,
                ),
                resources: ResourcesInfo(
                    cpuCount: 2, memoryTotalMB: 4_096, memoryUsedMB: 1_024, cpuLoadPercent: 5,
                ),
                storage: [],
                networking: NetworkingInfo(interfaces: []),
                virtualization: VirtualizationInfo(
                    accelerator: "tcg",
                    qemuCPUModel: "max",
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
            return try HomeDeviceProxyResponse(status: 200, body: JSONEncoder().encode(inventory))
        }
        if request.method == "GET", path == "/api/workloads/health-summary" {
            let summary = WorkloadHealthSummary(
                counts: ["running": 1],
                items: [WorkloadHealthSummaryItem(id: "vm-1", name: "one", health: .running)],
                updatedAt: "2026-08-14T00:00:00Z",
            )
            return try HomeDeviceProxyResponse(status: 200, body: JSONEncoder().encode(summary))
        }
        return HomeDeviceProxyResponse(status: 404, body: Data())
    }
}
