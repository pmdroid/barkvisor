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
