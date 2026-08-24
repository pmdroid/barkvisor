import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home devices controller health (PAS-52)")
struct HomeDevicesControllerTests {
    private func isolatedDir(_ label: String = "home-ctl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func controller(
        dir: URL,
        hostId: String,
        devices: DeviceRegistry? = nil,
        mtlsClient: (any HomeDeviceProxyClient)? = nil,
        vmManager: VMManager? = nil,
        localFacts: (@Sendable () async -> HomeDeviceLiveFacts)? = nil,
    ) -> HomeDevicesController {
        HomeDevicesController(
            dataDir: dir,
            hostId: hostId,
            devices: devices,
            mtlsClient: mtlsClient,
            vmManager: vmManager,
            localFacts: localFacts,
        )
    }

    private func localFacts(running: Int = 2) -> HomeDeviceLiveFacts {
        HomeDeviceLiveFacts(
            displayName: "this-device",
            collectedAt: "2026-08-14T00:00:00Z",
            platform: HomeDevicePlatformSummary(os: "linux", arch: "arm64"),
            resources: HomeDeviceResourceSummary(
                cpuCount: 2, memoryTotalMB: 4_096, memoryUsedMB: 1_024, cpuLoadPercent: 8,
            ),
            workloadCount: running,
            healthCounts: ["running": running],
        )
    }

    private func inventory(hostId: String, name: String) -> HostInventory {
        HostInventory(
            hostId: hostId,
            displayName: name,
            agent: AgentInfo(version: "test"),
            platform: PlatformInfo(
                os: "linux", osVersion: "6.8", arch: "arm64", hostname: name,
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
    }

    private func summary(running: Int, stopped: Int = 0) -> WorkloadHealthSummary {
        var items: [WorkloadHealthSummaryItem] = []
        items.append(contentsOf: (0 ..< running).map { index in
            WorkloadHealthSummaryItem(id: "run-\(index)", name: "run-\(index)", health: .running)
        })
        items.append(contentsOf: (0 ..< stopped).map { index in
            WorkloadHealthSummaryItem(id: "stop-\(index)", name: "stop-\(index)", health: .stopped)
        })
        return WorkloadHealthSummary(
            counts: ["running": running, "stopped": stopped],
            items: items,
            updatedAt: "2026-08-14T00:00:00Z",
        )
    }

    @Test func `probeMember builds member URLs, forwards bearer, and maps health`() async throws {
        let dir = try isolatedDir("probe-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let peerId = UUID().uuidString
        let client = RecordingProxyClient()
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "desk")),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 2, stopped: 1)),
        )
        let ctl = controller(dir: dir, hostId: UUID().uuidString, mtlsClient: client)
        let outcome = await ctl.probeMember(
            HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: "home-jwt",
        )
        guard case let .ok(facts) = outcome else {
            Issue.record("expected reachable member, got \(outcome)")
            return
        }
        #expect(facts.displayName == "desk")
        #expect(facts.workloadCount == 3)
        #expect(facts.healthCounts?["running"] == 2)
        #expect(facts.resources?.cpuCount == 2)
        #expect(facts.features?.kvmDevice == false)
        #expect(facts.features?.bridgedNetworking == false)
        #expect(facts.features?.usbPassthrough == false)

        let calls = client.calls
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.url.path)) == [
            "/api/agent/inventory",
            "/api/workloads/health-summary",
        ])
        for call in calls {
            #expect(call.method == "GET")
            #expect(call.url.host == "10.0.0.8")
            #expect(call.url.port == 7_778)
            #expect(call.url.scheme == "https")
            #expect(header("Authorization", in: call.headers) == "Bearer home-jwt")
            #expect(header("Accept", in: call.headers) == "application/json")
            #expect(
                header(APIContract.versionHeaderName, in: call.headers)
                    == String(APIContract.version),
            )
        }
    }

    @Test func `probeMember maps HTTP, decode, and transport errors without a blanket 502`() async throws {
        let dir = try isolatedDir("probe-err")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctlHTTP = controller(
            dir: dir,
            hostId: UUID().uuidString,
            mtlsClient: {
                let client = RecordingProxyClient()
                client.respond(
                    host: "10.0.0.8", port: 7_778, path: "/api/agent/inventory",
                    status: 503, body: Data("down".utf8),
                )
                return client
            }(),
        )
        let http = await ctlHTTP.probeMember(
            HomeDevice(hostId: "peer", role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: nil,
        )
        #expect(http == .failed(.memberHTTP(503)))

        let ctlDecode = controller(
            dir: dir,
            hostId: UUID().uuidString,
            mtlsClient: {
                let client = RecordingProxyClient()
                client.respond(
                    host: "10.0.0.8", port: 7_778, path: "/api/agent/inventory",
                    status: 200, body: Data("{".utf8),
                )
                return client
            }(),
        )
        let decoded = await ctlDecode.probeMember(
            HomeDevice(hostId: "peer", role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: nil,
        )
        guard case let .failed(decodeError) = decoded else {
            Issue.record("expected decode failure to be classified, got \(decoded)")
            return
        }
        #expect(decodeError.localizedDescription.contains("Device is unreachable") || decodeError.reachability != "ok")

        let failing = RecordingProxyClient()
        failing.fail(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            error: HomeDeviceProxyError.connectTimeout,
        )
        let ctlTransport = controller(dir: dir, hostId: UUID().uuidString, mtlsClient: failing)
        let transport = await ctlTransport.probeMember(
            HomeDevice(hostId: "peer", role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: "tok",
        )
        #expect(transport == .failed(.connectTimeout))

        let empty = await controller(dir: dir, hostId: UUID().uuidString, mtlsClient: RecordingProxyClient())
            .probeMember(HomeDevice(hostId: "ghost", role: "member"), bearer: nil)
        #expect(empty == .unreachable("Device has no reachable address"))
    }

    @Test func `healthReport probes every member and keeps this Device when one peer fails`() async throws {
        let dir = try isolatedDir("health-fanout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = UUID().uuidString
        let okId = "ok-peer"
        let downId = "down-peer"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: okId, fingerprint: "aa", agentHost: "10.0.0.2", agentPort: 7_778)
        try store.upsert(hostId: downId, fingerprint: "bb", agentHost: "10.0.0.3", agentPort: 7_778)

        let client = RecordingProxyClient()
        try client.respond(
            host: "10.0.0.2",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: okId, name: "ok-desk")),
        )
        try client.respond(
            host: "10.0.0.2",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 2)),
        )
        client.fail(
            host: "10.0.0.3",
            port: 7_778,
            path: "/api/agent/inventory",
            error: HomeDeviceProxyError.unreachable("peer down"),
        )

        let listed = HomeDeviceDirectory.list(
            dataDir: dir, hostId: selfId, displayName: "this-device", devices: store,
        )
        let ctl = controller(dir: dir, hostId: selfId, devices: store, mtlsClient: client)
        let report = await ctl.healthReport(
            listed: listed,
            local: localFacts(running: 1),
            bearer: "home-jwt",
        )

        #expect(report.devices.count == 3)
        let selfRow = try #require(report.devices.first { $0.role == "self" })
        #expect(selfRow.hostId == selfId)
        #expect(selfRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(selfRow.workloadCount == 1)

        let okRow = try #require(report.devices.first { $0.hostId == okId })
        #expect(okRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(okRow.displayName == "ok-desk")
        #expect(okRow.workloadCount == 2)

        let downRow = try #require(report.devices.first { $0.hostId == downId })
        #expect(downRow.reachability == HomeDeviceHealthAggregator.unreachable)
        #expect(downRow.workloadCount == nil)

        #expect(report.totals.reachable == 2)
        #expect(report.totals.unreachable == 1)
        #expect(report.totals.workloadCount == 3)

        let hosts = Set(client.calls.compactMap(\.url.host))
        #expect(hosts == ["10.0.0.2", "10.0.0.3"])
        #expect(client.calls.contains { $0.url.path == "/api/agent/inventory" && $0.url.host == "10.0.0.2" })
        #expect(client.calls.contains { $0.url.path == "/api/workloads/health-summary" && $0.url.host == "10.0.0.2" })
        #expect(client.calls.contains { $0.url.path == "/api/agent/inventory" && $0.url.host == "10.0.0.3" })
        #expect(client.calls.allSatisfy { header("Authorization", in: $0.headers) == "Bearer home-jwt" })
    }

    @Test func `probeMember treats health-summary transport and decode failures as unknown`() async throws {
        let dir = try isolatedDir("summary-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let peerId = "summary-peer"

        let decodeClient = RecordingProxyClient()
        try decodeClient.respond(
            host: "10.0.0.5",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "desk")),
        )
        decodeClient.respond(
            host: "10.0.0.5",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: Data("{".utf8),
        )
        let decoded = await controller(dir: dir, hostId: "self", mtlsClient: decodeClient)
            .probeMember(
                HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.5", agentPort: 7_778),
                bearer: nil,
            )
        guard case let .ok(decodeFacts) = decoded else {
            Issue.record("expected reachable member after summary decode failure, got \(decoded)")
            return
        }
        #expect(decodeFacts.workloadCount == nil)
        #expect(decodeFacts.healthCounts == nil)
        #expect(decodeFacts.displayName == "desk")

        let transportClient = RecordingProxyClient()
        try transportClient.respond(
            host: "10.0.0.5",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "desk")),
        )
        transportClient.fail(
            host: "10.0.0.5",
            port: 7_778,
            path: "/api/workloads/health-summary",
            error: HomeDeviceProxyError.unreachable("summary down"),
        )
        let transported = await controller(dir: dir, hostId: "self", mtlsClient: transportClient)
            .probeMember(
                HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.5", agentPort: 7_778),
                bearer: nil,
            )
        guard case let .ok(transportFacts) = transported else {
            Issue.record("expected reachable member after summary transport failure, got \(transported)")
            return
        }
        #expect(transportFacts.workloadCount == nil)
        #expect(transportFacts.healthCounts == nil)
        #expect(transportFacts.resources?.cpuCount == 2)
    }

    @Test func `connect timeout and member 5xx are not sold as Device offline`() async throws {
        let dir = try isolatedDir("hop-codes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let timeoutId = "timeout-peer"
        let httpId = "http-peer"
        let okId = "ok-peer"
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "this-device"),
            HomeDevice(hostId: timeoutId, role: "member", agentHost: "10.0.0.6", agentPort: 7_778),
            HomeDevice(hostId: httpId, role: "member", agentHost: "10.0.0.7", agentPort: 7_778),
            HomeDevice(hostId: okId, role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
        ])
        let client = RecordingProxyClient()
        client.fail(
            host: "10.0.0.6",
            port: 7_778,
            path: "/api/agent/inventory",
            error: HomeDeviceProxyError.connectTimeout,
        )
        client.respond(
            host: "10.0.0.7",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 503,
            body: Data("ollama down".utf8),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: okId, name: "ok-desk")),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 1)),
        )

        let report = await controller(dir: dir, hostId: "self", mtlsClient: client).healthReport(
            listed: listed,
            local: localFacts(running: 1),
            bearer: nil,
        )
        let timedOut = try #require(report.devices.first { $0.hostId == timeoutId })
        #expect(timedOut.reachability == HomeDeviceHealthAggregator.connectTimeout)
        #expect(timedOut.reachabilityError == HomeDeviceProxyError.connectTimeout.localizedDescription)
        #expect(timedOut.reachability != HomeDeviceHealthAggregator.unreachable)

        let http = try #require(report.devices.first { $0.hostId == httpId })
        #expect(http.reachability == HomeDeviceHealthAggregator.memberHTTP)
        #expect(http.reachabilityError == HomeDeviceProxyError.memberHTTP(503).localizedDescription)
        #expect(!(http.reachabilityError ?? "").hasPrefix("Device is unreachable:"))

        let okRow = try #require(report.devices.first { $0.hostId == okId })
        #expect(okRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(okRow.reachabilityError == nil)
        #expect(okRow.workloadCount == 1)
    }

    @Test func `inventory-only member stays reachable with unknown workload count`() async throws {
        let dir = try isolatedDir("inventory-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        let peerId = "inv-peer"
        let client = RecordingProxyClient()
        try client.respond(
            host: "10.0.0.4",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "inv")),
        )
        client.respond(
            host: "10.0.0.4",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 500,
            body: Data("nope".utf8),
        )
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "this-device"),
            HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.4", agentPort: 7_778),
        ])
        let report = await controller(dir: dir, hostId: "self", mtlsClient: client).healthReport(
            listed: listed,
            local: localFacts(running: 4),
            bearer: nil,
        )
        let peer = try #require(report.devices.first { $0.hostId == peerId })
        #expect(peer.reachability == HomeDeviceHealthAggregator.ok)
        #expect(peer.workloadCount == nil)
        #expect(report.totals.workloadCount == nil)
        #expect(report.totals.workloadCount != 0)
    }

    @Test func `local health summary failure does not invent zero workloads`() async throws {
        let dir = try isolatedDir("local-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        let hostId = UUID().uuidString
        let ctl = controller(dir: dir, hostId: hostId, vmManager: VMManager(dbPool: pool))
        let facts = await ctl.resolvedLocalFacts(db: pool)
        #expect(facts.workloadCount == nil)
        #expect(facts.healthCounts == nil)
        #expect(facts.resources != nil)

        let report = await ctl.healthReport(
            listed: HomeDeviceList(devices: [HomeDevice(hostId: hostId, role: "self")]),
            local: facts,
            bearer: nil,
        )
        #expect(report.devices.count == 1)
        #expect(report.devices[0].reachability == HomeDeviceHealthAggregator.ok)
        #expect(report.devices[0].workloadCount == nil)
        #expect(report.totals.workloadCount == nil)
        #expect(report.totals.workloadCount != 0)
    }

    @Test func `empty migrated database reports zero workloads not unknown`() async throws {
        let dir = try isolatedDir("local-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let hostId = UUID().uuidString
        let facts = await controller(
            dir: dir, hostId: hostId, vmManager: VMManager(dbPool: pool),
        ).resolvedLocalFacts(db: pool)
        #expect(facts.workloadCount == 0)
        #expect(facts.healthCounts != nil)
        #expect(facts.features != nil)
    }

    @Test func `placement score keeps this Device when a peer is down`() async throws {
        let dir = try isolatedDir("place-down")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = "self-host"
        let downId = "down-peer"
        let client = RecordingProxyClient()
        client.fail(
            host: "10.0.0.9",
            port: 7_778,
            path: "/api/agent/inventory",
            error: HomeDeviceProxyError.unreachable("peer down"),
        )
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: selfId, role: "self", displayName: "this-device"),
            HomeDevice(hostId: downId, role: "member", agentHost: "10.0.0.9", agentPort: 7_778),
        ])
        var local = localFacts(running: 1)
        local.features = HomeDeviceFeatureSummary(
            kvmDevice: true, bridgedNetworking: true, usbPassthrough: false,
        )
        let scored = await controller(dir: dir, hostId: selfId, mtlsClient: client).scorePlacement(
            request: HomePlacementScoreRequest(
                declaredArchitectures: ["arm64"],
                requiredFeatures: ["kvmDevice"],
                minMemoryMB: 512,
            ),
            listed: listed,
            local: local,
            bearer: "home-jwt",
        )
        #expect(scored.recommendedHostId == selfId)
        let selfRow = try #require(scored.candidates.first { $0.hostId == selfId })
        #expect(selfRow.eligible)
        #expect(selfRow.recommended)
        let down = try #require(scored.candidates.first { $0.hostId == downId })
        #expect(!down.eligible)
        #expect(down.reasons.contains { $0.code == HomePlacementScorer.offlineCode })
    }
}

private func header(_ name: String, in headers: [(String, String)]) -> String? {
    headers.first { $0.0.lowercased() == name.lowercased() }?.1
}

/// In-memory mTLS stand-in. Records every request so tests can assert URL,
/// auth, and fan-out without binding sockets.
private final class RecordingProxyClient: HomeDeviceProxyClient, @unchecked Sendable {
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

    func respond(host: String, port: Int, path: String, status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses[key(host: host, port: port, path: path)] = .success(
            HomeDeviceProxyResponse(status: status, body: body),
        )
    }

    func fail(host: String, port: Int, path: String, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        responses[key(host: host, port: port, path: path)] = .failure(error)
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
        return responses[key(url: request.url)]
    }

    private func key(host: String, port: Int, path: String) -> String {
        "\(host):\(port)\(path)"
    }

    private func key(url: URL) -> String {
        key(host: url.host ?? "", port: url.port ?? 0, path: url.path)
    }
}
