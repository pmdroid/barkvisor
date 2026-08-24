import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// PAS-47 / PAS-90 acceptance: a down member must not take this Device with it.
///
/// Demo: pair two Devices, start a local VM, stop the peer process (or unplug
/// it). Local VMs stay in SQLite and keep their state. The Home dashboard
/// marks that Device unreachable and does not invent its workload counts.
/// There is no controller and pairing is unchanged.
@Suite("Member-down demo (PAS-47)")
struct MemberDownDemoTests {
    private func isolatedDir(_ label: String = "member-down") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `member down keeps local VMs and marks the Device unreachable`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)

        let now = "2026-08-14T00:00:00Z"
        try await pool.write { db in
            try insertDisk(id: "disk-run", vmId: "vm-run", at: now).insert(db)
            try insertDisk(id: "disk-stop", vmId: "vm-stop", at: now).insert(db)
            try insertVM(id: "vm-run", name: "keep-running", state: "running", diskId: "disk-run", at: now)
                .insert(db)
            try insertVM(id: "vm-stop", name: "already-stopped", state: "stopped", diskId: "disk-stop", at: now)
                .insert(db)
        }

        let selfId = UUID().uuidString
        let downId = "down-peer"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: downId, fingerprint: "aa", agentHost: "10.0.0.9", agentPort: 7_778)

        let client = FailingMemberClient()
        client.fail(
            host: "10.0.0.9",
            port: 7_778,
            path: "/api/agent/inventory",
            error: HomeDeviceProxyError.unreachable("peer down"),
        )

        let listed = HomeDeviceDirectory.list(
            dataDir: dir, hostId: selfId, displayName: "this-device", devices: store,
        )
        let vmManager = VMManager(dbPool: pool)
        let ctl = HomeDevicesController(
            dataDir: dir,
            hostId: selfId,
            devices: store,
            mtlsClient: client,
            vmManager: vmManager,
        )

        // Local facts come from this Device's SQLite rows, not from the peer.
        let rows = try await pool.read { try VM.fetchAll($0) }
        let local = localFacts(from: rows, at: now)

        let report = await ctl.healthReport(listed: listed, local: local, bearer: "home-jwt")

        #expect(report.devices.count == 2)
        let selfRow = try #require(report.devices.first { $0.role == "self" })
        #expect(selfRow.hostId == selfId)
        #expect(selfRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(selfRow.workloadCount == 2)
        #expect(selfRow.healthCounts?["running"] == 1)
        #expect(selfRow.healthCounts?["stopped"] == 1)

        let down = try #require(report.devices.first { $0.hostId == downId })
        #expect(down.reachability == HomeDeviceHealthAggregator.unreachable)
        #expect(down.workloadCount == nil)
        #expect(down.healthCounts == nil)
        #expect(down.resources == nil)

        #expect(report.totals.reachable == 1)
        #expect(report.totals.unreachable == 1)
        #expect(report.totals.workloadCount == 2)
        #expect(report.totals.healthCounts["running"] == 1)
        #expect(client.calls.contains { $0.url.host == "10.0.0.9" })

        // Peer failure must not mutate or lock local SQLite / QEMU records.
        let after = try await pool.read { try VM.fetchAll($0) }
        #expect(Set(after.map(\.id)) == ["vm-run", "vm-stop"])
        #expect(after.first { $0.id == "vm-run" }?.state == "running")
        #expect(after.first { $0.id == "vm-stop" }?.state == "stopped")

        let summary = try await HomeDevicesController.localHealthSummary(
            db: pool, vmManager: vmManager, healthProbes: nil,
        )
        #expect(Set(summary.items.map(\.id)) == ["vm-run", "vm-stop"])

        try await vmManager.updateState(vmID: "vm-run", state: "running")
        try await pool.write { db in
            try insertDisk(id: "disk-new", vmId: "vm-new", at: now).insert(db)
            try insertVM(id: "vm-new", name: "still-writable", state: "stopped", diskId: "disk-new", at: now)
                .insert(db)
        }
        let written = try await pool.read { try VM.fetchOne($0, key: "vm-new") }
        #expect(written?.state == "stopped")
        #expect(try await pool.read { try VM.fetchOne($0, key: "vm-run") }?.state == "running")
    }

    @Test func `error 1 connect timeout is hop failure, member 5xx is not offline, ok health stays ok`() async throws {
        let dir = try isolatedDir("hop-vs-health")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = UUID().uuidString
        let timeoutId = "timeout-peer"
        let httpId = "http-peer"
        let okId = "ok-peer"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: timeoutId, fingerprint: "aa", agentHost: "10.0.0.6", agentPort: 7_778)
        try store.upsert(hostId: httpId, fingerprint: "bb", agentHost: "10.0.0.7", agentPort: 7_778)
        try store.upsert(hostId: okId, fingerprint: "cc", agentHost: "10.0.0.8", agentPort: 7_778)

        let error1 = NSError(
            domain: "AsyncHTTPClient.HTTPClientError",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The operation could not be completed. (AsyncHTTPClient.HTTPClientError error 1.)",
            ],
        )
        let client = FailingMemberClient()
        client.fail(
            host: "10.0.0.6",
            port: 7_778,
            path: "/api/agent/inventory",
            error: HomeDeviceProxyError.classify(error1),
        )
        client.respond(
            host: "10.0.0.7",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 503,
            body: Data("down".utf8),
        )
        let inventory = HostInventory(
            hostId: okId,
            displayName: "ok-desk",
            agent: AgentInfo(version: "test"),
            platform: PlatformInfo(
                os: "linux", osVersion: "6.8", arch: "arm64", hostname: "ok-desk",
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
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory),
        )
        client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 500,
            body: Data("nope".utf8),
        )

        let listed = HomeDeviceDirectory.list(
            dataDir: dir, hostId: selfId, displayName: "this-device", devices: store,
        )
        let ctl = HomeDevicesController(
            dataDir: dir,
            hostId: selfId,
            devices: store,
            mtlsClient: client,
        )
        let report = await ctl.healthReport(
            listed: listed,
            local: localFacts(from: [], at: "2026-08-14T00:00:00Z"),
            bearer: nil,
        )

        let timedOut = try #require(report.devices.first { $0.hostId == timeoutId })
        #expect(timedOut.reachability == HomeDeviceHealthAggregator.connectTimeout)
        #expect(timedOut.reachabilityError?.contains("Home cannot hop") == true)
        #expect(!(timedOut.reachabilityError ?? "").hasPrefix("Device is unreachable:"))

        let http = try #require(report.devices.first { $0.hostId == httpId })
        #expect(http.reachability == HomeDeviceHealthAggregator.memberHTTP)
        #expect(http.reachabilityError == "Device returned HTTP 503")

        let okRow = try #require(report.devices.first { $0.hostId == okId })
        #expect(okRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(okRow.reachabilityError == nil)
        #expect(okRow.workloadCount == nil)
    }
}

private func localFacts(from rows: [VM], at: String) -> HomeDeviceLiveFacts {
    HomeDeviceLiveFacts(
        displayName: "this-device",
        collectedAt: at,
        platform: HomeDevicePlatformSummary(os: "linux", arch: "arm64"),
        resources: HomeDeviceResourceSummary(
            cpuCount: 2, memoryTotalMB: 4_096, memoryUsedMB: 1_024, cpuLoadPercent: 8,
        ),
        workloadCount: rows.count,
        healthCounts: [
            "running": rows.count(where: { $0.state == "running" }),
            "stopped": rows.count(where: { $0.state == "stopped" }),
        ],
    )
}

private func insertDisk(id: String, vmId: String, at: String) -> Disk {
    Disk(
        id: id,
        name: id,
        path: "/tmp/\(id).qcow2",
        sizeBytes: 1_024,
        format: "qcow2",
        vmId: vmId,
        autoCreated: false,
        status: "ready",
        createdAt: at,
    )
}

private func insertVM(id: String, name: String, state: String, diskId: String, at: String) -> VM {
    VM(
        id: id,
        name: name,
        vmType: "linux-arm64",
        state: state,
        cpuCount: 2,
        memoryMb: 2_048,
        bootDiskId: diskId,
        networkId: nil,
        cloudInitPath: nil,
        description: nil,
        bootOrder: "cd",
        displayResolution: "1280x800",
        additionalDiskIds: nil,
        uefi: true,
        tpmEnabled: false,
        macAddress: nil,
        sharedPaths: nil,
        portForwards: nil,
        autoCreated: false,
        pendingChanges: false,
        createdAt: at,
        updatedAt: at,
    )
}

/// In-memory mTLS stand-in. A down member never reaches a real socket.
private final class FailingMemberClient: HomeDeviceProxyClient, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var headers: [(String, String)]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [String: Result<HomeDeviceProxyResponse, Error>] = [:]

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func fail(host: String, port: Int, path: String, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(host):\(port)\(path)"] = .failure(error)
    }

    func respond(host: String, port: Int, path: String, status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(host):\(port)\(path)"] = .success(
            HomeDeviceProxyResponse(status: status, body: body),
        )
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        switch record(request) {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        case nil:
            return HomeDeviceProxyResponse(status: 404, body: Data())
        }
    }

    private func record(_ request: HomeDeviceProxyRequest) -> Result<HomeDeviceProxyResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(Call(method: request.method, url: request.url, headers: request.headers))
        return responses["\(request.url.host ?? ""):\(request.url.port ?? 0)\(request.url.path)"]
    }
}
