import AsyncHTTPClient
import Foundation
import GRDB
import JWTKit
import NIOCore
import NIOPosix
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home devices controller health (PAS-52)")
struct HomeDevicesControllerTests {
    private let responseMappingBudgetNanoseconds: UInt64 = 120_000_000_000

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
        reachability: HomeDeviceReachabilityMonitor = HomeDeviceReachabilityMonitor(),
        keys: JWTKeyCollection? = nil,
    ) -> HomeDevicesController {
        HomeDevicesController(
            dataDir: dir,
            hostId: hostId,
            devices: devices,
            mtlsClient: mtlsClient,
            vmManager: vmManager,
            localFacts: localFacts,
            reachability: reachability,
            keys: keys,
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

    @Test func `home-owned reachability permits application failures but suppresses transport failures`() async {
        let monitor = HomeDeviceReachabilityMonitor()
        await monitor.replace([
            "application-error": HomeDeviceHealthAggregator.memberHTTP,
            "timed-out": HomeDeviceHealthAggregator.connectTimeout,
        ])

        #expect(await monitor.permitsHop(to: "application-error"))
        let timedOutPermitted = await monitor.permitsHop(to: "timed-out")
        #expect(!timedOutPermitted)
        #expect(await monitor.permitsHop(to: "unknown-member"))
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
        #expect(facts.doctor == nil)

        let calls = client.calls
        #expect(calls.count == 3)
        #expect(Set(calls.map(\.url.path)) == [
            "/api/agent/inventory",
            "/api/workloads/health-summary",
            "/api/system/doctor",
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
            probeBudgetNanoseconds: responseMappingBudgetNanoseconds,
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
        #expect(try store.record(forHostId: okId)?.displayName == "ok-desk")

        let downRow = try #require(report.devices.first { $0.hostId == downId })
        #expect(downRow.reachability == HomeDeviceHealthAggregator.unreachable)
        #expect(downRow.workloadCount == nil)

        #expect(report.totals.reachable == 2)
        #expect(report.totals.unreachable == 1)
        #expect(report.totals.workloadCount == 3)

        let laterListed = HomeDeviceDirectory.list(
            dataDir: dir, hostId: selfId, displayName: "this-device", devices: store,
        )
        let laterReport = HomeDeviceHealthAggregator.report(
            listed: laterListed,
            local: localFacts(running: 1),
            members: [okId: .unreachable("peer down"), downId: .unreachable("peer down")],
        )
        #expect(laterReport.devices.first { $0.hostId == okId }?.displayName == "ok-desk")

        let hosts = Set(client.calls.compactMap(\.url.host))
        #expect(hosts == ["10.0.0.2", "10.0.0.3"])
        #expect(client.calls.contains { $0.url.path == "/api/agent/inventory" && $0.url.host == "10.0.0.2" })
        #expect(client.calls.contains { $0.url.path == "/api/workloads/health-summary" && $0.url.host == "10.0.0.2" })
        #expect(client.calls.contains { $0.url.path == "/api/system/doctor" && $0.url.host == "10.0.0.2" })
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
        #expect(transportFacts.doctor == nil)
    }

    @Test func `probeMember maps doctor failures and ignores a broken doctor hop`() async throws {
        let dir = try isolatedDir("probe-doctor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let peerId = "doctor-peer"
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
            body: JSONEncoder().encode(summary(running: 1)),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/system/doctor",
            status: 200,
            body: JSONEncoder().encode(DoctorReport(
                ok: false,
                privileged: true,
                checks: [
                    DoctorCheck(id: "qemu", status: .fail, detail: "qemu-system-aarch64 not found."),
                    DoctorCheck(id: "swtpm", status: .fail, detail: "swtpm not found."),
                    DoctorCheck(id: "daemon-uid", status: .warn, detail: "uid=501"),
                ],
                hostBridge: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()).readiness,
            )),
        )
        let outcome = await controller(dir: dir, hostId: "self", mtlsClient: client).probeMember(
            HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: "home-jwt",
        )
        guard case let .ok(facts) = outcome else {
            Issue.record("expected reachable member, got \(outcome)")
            return
        }
        let doctor = try #require(facts.doctor)
        #expect(!doctor.ok)
        #expect(doctor.failures.map(\.id) == ["qemu", "swtpm"])
        #expect(doctor.failures.contains { $0.detail.contains("qemu-system") })

        let broken = RecordingProxyClient()
        try broken.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "desk")),
        )
        try broken.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 1)),
        )
        broken.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/system/doctor",
            status: 200,
            body: Data("{".utf8),
        )
        let decoded = await controller(dir: dir, hostId: "self", mtlsClient: broken).probeMember(
            HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            bearer: nil,
        )
        guard case let .ok(brokenFacts) = decoded else {
            Issue.record("expected reachable member after doctor decode failure, got \(decoded)")
            return
        }
        #expect(brokenFacts.doctor == nil)
        #expect(brokenFacts.workloadCount == 1)
    }

    @Test func `healthReport budget times out a hung member and keeps this Device`() async throws {
        let dir = try isolatedDir("health-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hungId = "hung-peer"
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "this-device"),
            HomeDevice(hostId: hungId, role: "member", agentHost: "10.0.0.11", agentPort: 7_778),
        ])
        let client = RecordingProxyClient()
        client.hang(host: "10.0.0.11", port: 7_778, path: "/api/agent/inventory")
        let report = await controller(dir: dir, hostId: "self", mtlsClient: client).healthReport(
            listed: listed,
            local: localFacts(running: 1),
            bearer: nil,
            probeBudgetNanoseconds: 50_000_000,
        )
        let selfRow = try #require(report.devices.first { $0.role == "self" })
        #expect(selfRow.hostId == "self")
        #expect(selfRow.reachability == HomeDeviceHealthAggregator.ok)
        #expect(selfRow.workloadCount == 1)
        let hung = try #require(report.devices.first { $0.hostId == hungId })
        #expect(hung.reachability == HomeDeviceHealthAggregator.connectTimeout)
        #expect(hung.reachabilityError == HomeDeviceProxyError.connectTimeout.localizedDescription)
        #expect(hung.reachability != HomeDeviceHealthAggregator.ok)
        #expect(HomeDeviceProxy.hopTimeoutSeconds == 2)
        #expect(HomeDeviceProxy.healthProbeBudgetNanoseconds == 2_500_000_000)
    }

    @Test func `healthReport skips a member already known unreachable`() async throws {
        let dir = try isolatedDir("health-skip-down")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hungId = "hung-peer"
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "this-device"),
            HomeDevice(hostId: hungId, role: "member", agentHost: "10.0.0.11", agentPort: 7_778),
        ])
        let client = RecordingProxyClient()
        client.hang(host: "10.0.0.11", port: 7_778, path: "/api/agent/inventory")
        let monitor = HomeDeviceReachabilityMonitor()
        await monitor.replace([hungId: HomeDeviceHealthAggregator.connectTimeout])
        let started = ContinuousClock.now
        let report = await controller(
            dir: dir,
            hostId: "self",
            mtlsClient: client,
            reachability: monitor,
        ).healthReport(
            listed: listed,
            local: localFacts(running: 1),
            bearer: nil,
            probeBudgetNanoseconds: 2_000_000_000,
        )
        let elapsed = started.duration(to: .now)
        #expect(elapsed < Duration.milliseconds(400))
        #expect(client.calls.isEmpty)
        let hung = try #require(report.devices.first { $0.hostId == hungId })
        #expect(hung.reachability == HomeDeviceHealthAggregator.connectTimeout)
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
            probeBudgetNanoseconds: responseMappingBudgetNanoseconds,
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
            probeBudgetNanoseconds: responseMappingBudgetNanoseconds,
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

    @Test func `health hop bearer stays local when Home has no User`() async throws {
        let dir = try isolatedDir("health-hop-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "home-hop-empty-secret"), digestAlgorithm: .sha256)
        let ctl = controller(dir: dir, hostId: "self", keys: keys)
        let bearer = await ctl.hopBearerForHealth(
            user: AuthBypass.syntheticAdmin,
            db: pool,
            incoming: "keep-me",
        )
        #expect(bearer == "keep-me")
        let empty = await ctl.hopBearerForHealth(
            user: AuthBypass.syntheticAdmin,
            db: pool,
            incoming: nil,
        )
        #expect(empty == nil)
    }

    @Test func `bypass hop authorization mints the provisioned admin JWT`() async throws {
        let dir = try isolatedDir("bypass-hop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try await pool.write { db in
            try User(
                id: "admin-1",
                username: "pascal",
                password: "hashed:unused-password",
                createdAt: "2026-01-01T00:00:00Z",
                role: UserRole.admin.rawValue,
            ).insert(db)
        }
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "home-hop-test-secret"), digestAlgorithm: .sha256)
        let ctl = controller(dir: dir, hostId: "self", keys: keys)
        let token = try await ctl.hopAuthorization(
            user: AuthBypass.syntheticAdmin,
            db: pool,
            incoming: nil,
        )
        let hop = try #require(token)
        #expect(!hop.hasPrefix("barkvisor_"))
        let payload = try await keys.verify(hop, as: UserPayload.self)
        #expect(payload.sub.value == "admin-1")
        #expect(payload.username == "pascal")
        #expect(payload.role == UserRole.admin.rawValue)
        #expect(payload.sub.value != AuthBypass.syntheticUserId)
    }

    @Test func `health probe with keys sends hop JWT when the caller has no bearer`() async throws {
        let dir = try isolatedDir("health-hop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try await pool.write { db in
            try User(
                id: "admin-1",
                username: "pascal",
                password: "hashed:unused-password",
                createdAt: "2026-01-01T00:00:00Z",
                role: UserRole.admin.rawValue,
            ).insert(db)
        }
        let peerId = "agentbox"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "aa", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = RecordingProxyClient()
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "agentbox")),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 1)),
        )
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "home-hop-test-secret"), digestAlgorithm: .sha256)
        let ctl = controller(dir: dir, hostId: "self", devices: store, mtlsClient: client, keys: keys)
        let bearer = try await ctl.hopAuthorization(
            user: AuthBypass.syntheticAdmin,
            db: pool,
            incoming: nil,
        )
        let listed = HomeDeviceDirectory.list(
            dataDir: dir, hostId: "self", displayName: "this-device", devices: store,
        )
        let report = await ctl.healthReport(
            listed: listed,
            local: localFacts(running: 1),
            bearer: bearer,
            probeBudgetNanoseconds: responseMappingBudgetNanoseconds,
        )
        let peer = try #require(report.devices.first { $0.hostId == peerId })
        #expect(peer.reachability == HomeDeviceHealthAggregator.ok)
        #expect(peer.displayName == "agentbox")
        let auth = try #require(header("Authorization", in: client.calls[0].headers))
        #expect(auth.hasPrefix("Bearer "))
        let token = String(auth.dropFirst("Bearer ".count))
        let payload = try await keys.verify(token, as: UserPayload.self)
        #expect(payload.sub.value == "admin-1")
        #expect(payload.sub.value != AuthBypass.syntheticUserId)
    }

    @Test func `two placement scores inside five seconds probe once`() async throws {
        let dir = try isolatedDir("place-reuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = "self-host"
        let peerId = "peer-host"
        let client = RecordingProxyClient()
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: peerId, name: "zimaboard")),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 1)),
        )
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: selfId, role: "self", displayName: "this-device"),
            HomeDevice(hostId: peerId, role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
        ])
        var local = localFacts(running: 1)
        local.features = HomeDeviceFeatureSummary(
            kvmDevice: true, bridgedNetworking: true, usbPassthrough: false,
        )
        let ctl = controller(dir: dir, hostId: selfId, mtlsClient: client)
        let request = HomePlacementScoreRequest(
            declaredArchitectures: ["arm64"],
            requiredFeatures: ["kvmDevice"],
            minMemoryMB: 512,
        )
        let first = await ctl.scorePlacement(
            request: request, listed: listed, local: local, bearer: nil,
        )
        let callsAfterFirst = client.calls.count
        #expect(callsAfterFirst > 0)
        let second = await ctl.scorePlacement(
            request: request, listed: listed, local: local, bearer: nil,
        )
        #expect(client.calls.count == callsAfterFirst)
        #expect(first.recommendedHostId == selfId)
        #expect(second.recommendedHostId == first.recommendedHostId)
        #expect(second.candidates.map(\.hostId) == first.candidates.map(\.hostId))
        let selfRow = try #require(second.candidates.first { $0.hostId == selfId })
        #expect(selfRow.eligible)
        let peer = try #require(second.candidates.first { $0.hostId == peerId })
        #expect(!peer.eligible)
        #expect(peer.reasons.contains { $0.code == HomePlacementScorer.featureMissingCode })
    }

    @Test func `placement score does not call DockerEngine.liveSnapshot`() async throws {
        let dir = try isolatedDir("place-docker")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let shared = DockerDiscoveryCache.shared
        let previousSchedule = shared.scheduleRefresh
        let parked = ParkedDockerRefresh()
        shared.scheduleRefresh = { parked.add($0) }
        defer {
            shared.cancelPendingRefresh()
            shared.scheduleRefresh = previousSchedule
        }
        let ctl = controller(dir: dir, hostId: "self-host")
        let guardProbe = LiveSnapshotGuard(
            replacement: DockerEngineSnapshot(os: PlatformHost.platformName),
        )
        let facts = await DockerEngine.$liveSnapshotGuard.withValue(guardProbe) {
            await ctl.resolvedLocalFacts(db: pool)
        }
        #expect(guardProbe.callCount == 0)
        #expect(facts.features != nil)
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self-host", role: "self", displayName: "this-device"),
        ])
        let scored = await ctl.scorePlacement(
            request: HomePlacementScoreRequest(
                declaredArchitectures: ["arm64"],
                requiredFeatures: ["kvmDevice"],
                minMemoryMB: 512,
            ),
            listed: listed,
            local: facts,
            bearer: nil,
        )
        #expect(scored.candidates.contains { $0.hostId == "self-host" })
    }

    @Test func `dead member score returns inside the probe budget`() async throws {
        let dir = try isolatedDir("place-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = "self-host"
        let liveId = "live-peer"
        let deadId = "dead-peer"
        let client = StallingProxyClient()
        client.stall(host: "10.0.0.11", port: 7_778, path: "/api/agent/inventory")
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/agent/inventory",
            status: 200,
            body: JSONEncoder().encode(inventory(hostId: liveId, name: "goldbox")),
        )
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/workloads/health-summary",
            status: 200,
            body: JSONEncoder().encode(summary(running: 2)),
        )
        defer { client.release() }
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: selfId, role: "self", displayName: "this-device"),
            HomeDevice(hostId: liveId, role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
            HomeDevice(hostId: deadId, role: "member", agentHost: "10.0.0.11", agentPort: 7_778),
        ])
        var local = localFacts(running: 1)
        local.features = HomeDeviceFeatureSummary(
            kvmDevice: true, bridgedNetworking: false, usbPassthrough: false,
        )
        let facts = local
        let ctl = controller(dir: dir, hostId: selfId, mtlsClient: client)
        let budget: UInt64 = 80_000_000
        let started = ContinuousClock.now
        let scored = try await firstScore(
            withinNanoseconds: 1_000_000_000,
            body: {
                await ctl.scorePlacement(
                    request: HomePlacementScoreRequest(
                        declaredArchitectures: ["arm64"],
                        minMemoryMB: 512,
                    ),
                    listed: listed,
                    local: facts,
                    bearer: nil,
                    probeBudgetNanoseconds: budget,
                )
            },
        )
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .milliseconds(700))
        #expect(HomeDeviceProxy.healthProbeBudgetNanoseconds == 2_500_000_000)
        #expect(client.stillStalled)
        let selfRow = try #require(scored.candidates.first { $0.hostId == selfId })
        #expect(selfRow.eligible)
        let live = try #require(scored.candidates.first { $0.hostId == liveId })
        #expect(live.eligible)
        let dead = try #require(scored.candidates.first { $0.hostId == deadId })
        #expect(!dead.eligible)
        #expect(dead.reasons.contains { $0.code == HomePlacementScorer.offlineCode })
    }

    @Test func `recorded connect timeout is not probed on the next score`() async throws {
        let dir = try isolatedDir("place-skip-timeout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = "self-host"
        let deadId = "dead-peer"
        let client = StallingProxyClient()
        client.stall(host: "10.0.0.11", port: 7_778, path: "/api/agent/inventory")
        defer { client.release() }
        let monitor = HomeDeviceReachabilityMonitor()
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: selfId, role: "self", displayName: "this-device"),
            HomeDevice(hostId: deadId, role: "member", agentHost: "10.0.0.11", agentPort: 7_778),
        ])
        let ctl = controller(dir: dir, hostId: selfId, mtlsClient: client, reachability: monitor)
        _ = try await firstScore(withinNanoseconds: 1_000_000_000) {
            await ctl.scorePlacement(
                request: HomePlacementScoreRequest(declaredArchitectures: ["arm64"], minMemoryMB: 512),
                listed: listed,
                local: localFacts(running: 1),
                bearer: nil,
                probeBudgetNanoseconds: 80_000_000,
            )
        }
        let callsAfterTimeout = client.calls.count
        #expect(callsAfterTimeout > 0)
        #expect(await monitor.permitsHop(to: deadId) == false)
        client.release()
        let second = await ctl.scorePlacement(
            request: HomePlacementScoreRequest(declaredArchitectures: ["arm64"], minMemoryMB: 512),
            listed: listed,
            local: localFacts(running: 1),
            bearer: nil,
            probeBudgetNanoseconds: 2_000_000_000,
        )
        #expect(client.calls.count == callsAfterTimeout)
        let dead = try #require(second.candidates.first { $0.hostId == deadId })
        #expect(!dead.eligible)
        let selfRow = try #require(second.candidates.first { $0.hostId == selfId })
        #expect(selfRow.eligible)
    }

    @Test func `cancelling a member connect closes the socket`() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let accepted = CloseSignal()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(CloseWatch(signal: accepted))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        var config = HTTPClient.Configuration()
        config.timeout = .init(connect: .seconds(10), read: .seconds(10))
        let http = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
        defer { stopProbeServer(http, server, group) }
        let port = server.localAddress?.port ?? 0
        #expect(port > 0)
        let task = Task {
            var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/api/agent/inventory")
            request.method = .GET
            _ = try await ProbeConnect.execute(request: request, client: http, timeout: .seconds(10))
        }
        let connected = await accepted.waitConnected(nanoseconds: 1_000_000_000)
        #expect(connected)
        task.cancel()
        let closed = await accepted.waitClosed(nanoseconds: 1_000_000_000)
        #expect(closed)
        _ = await task.result
    }
}

private enum ScoreRace {
    case scored(HomePlacementScoreResponse)
    case hung
}

private func firstScore(
    withinNanoseconds budget: UInt64,
    body: @escaping @Sendable () async -> HomePlacementScoreResponse,
) async throws -> HomePlacementScoreResponse {
    let winner = await withTaskGroup(of: ScoreRace.self) { group in
        group.addTask {
            await .scored(body())
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: budget)
            return .hung
        }
        let winner = await group.next() ?? .hung
        group.cancelAll()
        return winner
    }
    guard case let .scored(scored) = winner else { throw PlacementScoreHung() }
    return scored
}

private struct PlacementScoreHung: Error {}

private final class ParkedDockerRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [() -> Void] = []

    func add(_ item: @escaping @Sendable () -> Void) {
        lock.lock()
        work.append(item)
        lock.unlock()
    }
}

private final class CloseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var connectedContinuation: CheckedContinuation<Void, Never>?
    private var closedContinuation: CheckedContinuation<Void, Never>?
    private var connected = false
    private var closed = false

    func markConnected() {
        lock.lock()
        connected = true
        let continuation = connectedContinuation
        connectedContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func markClosed() {
        lock.lock()
        closed = true
        let continuation = closedContinuation
        closedContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitConnected(nanoseconds: UInt64) async -> Bool {
        await race(nanoseconds: nanoseconds) {
            await withCheckedContinuation { continuation in
                self.armConnected(continuation)
            }
        }
    }

    func waitClosed(nanoseconds: UInt64) async -> Bool {
        await race(nanoseconds: nanoseconds) {
            await withCheckedContinuation { continuation in
                self.armClosed(continuation)
            }
        }
    }

    private func race(
        nanoseconds: UInt64,
        untilReady: @escaping @Sendable () async -> Void,
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await untilReady()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }
            let won = await group.next() ?? false
            group.cancelAll()
            return won
        }
    }

    private func armConnected(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if connected {
            lock.unlock()
            continuation.resume()
            return
        }
        connectedContinuation = continuation
        lock.unlock()
    }

    private func armClosed(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if closed {
            lock.unlock()
            continuation.resume()
            return
        }
        closedContinuation = continuation
        lock.unlock()
    }
}

private final class CloseWatch: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let signal: CloseSignal

    init(signal: CloseSignal) {
        self.signal = signal
    }

    func channelActive(context: ChannelHandlerContext) {
        signal.markConnected()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        signal.markClosed()
        context.fireChannelInactive()
    }
}

private final class StallingProxyClient: HomeDeviceProxyClient, @unchecked Sendable {
    private let inner = RecordingProxyClient()
    private let lock = NSLock()
    private var stalls: Set<String> = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var _calls: [RecordingProxyClient.Call] = []
    private var openStalls = 0

    var calls: [RecordingProxyClient.Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var stillStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openStalls > 0
    }

    func respond(host: String, port: Int, path: String, status: Int, body: Data) {
        inner.respond(host: host, port: port, path: path, status: status, body: body)
    }

    func stall(host: String, port: Int, path: String) {
        lock.lock()
        stalls.insert("\(host):\(port)\(path)")
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        let parked = self.parked
        self.parked = []
        openStalls = 0
        lock.unlock()
        for continuation in parked {
            continuation.resume()
        }
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        let stall = record(request)
        if stall {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.park(continuation)
                }
            } onCancel: {
                self.noteCancel()
            }
            throw CancellationError()
        }
        return try await inner.send(request)
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released {
            lock.unlock()
            continuation.resume()
            return
        }
        openStalls += 1
        parked.append(continuation)
        lock.unlock()
    }

    private func noteCancel() {}

    private func record(_ request: HomeDeviceProxyRequest) -> Bool {
        let key = "\(request.url.host ?? ""):\(request.url.port ?? 0)\(request.url.path)"
        lock.lock()
        defer { lock.unlock() }
        _calls.append(RecordingProxyClient.Call(
            method: request.method, url: request.url, headers: request.headers,
        ))
        return stalls.contains(key)
    }
}

private func stopProbeServer(
    _ http: HTTPClient,
    _ server: Channel,
    _ group: MultiThreadedEventLoopGroup,
) {
    try? http.syncShutdown()
    try? server.close().wait()
    try? group.syncShutdownGracefully()
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
    private var hangs: Set<String> = []

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

    func hang(host: String, port: Int, path: String) {
        lock.lock()
        defer { lock.unlock() }
        hangs.insert(key(host: host, port: port, path: path))
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        let recorded = record(request)
        if recorded.hang {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw CancellationError()
        }
        switch recorded.response {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        case nil:
            return HomeDeviceProxyResponse(status: 404, body: Data())
        }
    }

    private func record(
        _ request: HomeDeviceProxyRequest,
    ) -> (response: Result<HomeDeviceProxyResponse, Error>?, hang: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(Call(method: request.method, url: request.url, headers: request.headers))
        let pathKey = key(url: request.url)
        return (responses[pathKey], hangs.contains(pathKey))
    }

    private func key(host: String, port: Int, path: String) -> String {
        "\(host):\(port)\(path)"
    }

    private func key(url: URL) -> String {
        key(host: url.host ?? "", port: url.port ?? 0, path: url.path)
    }
}
