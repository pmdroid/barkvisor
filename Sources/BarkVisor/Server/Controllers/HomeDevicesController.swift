import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// Home device registry + member proxy (PAS-34), aggregated health (PAS-52),
/// and placement scoring (PAS-44).
///
/// JWT on 7777. Listing is local-only. Health best-effort probes members
/// over mTLS; this Device stays in the report if a peer is down (PAS-47).
struct HomeDevicesController: RouteCollection {
    var devices: DeviceRegistry?
    var mtlsClient: (any HomeDeviceProxyClient)?
    var localClient: any HomeDeviceProxyClient
    var dataDir: URL
    var hostId: String
    var localPort: Int
    var vmManager: VMManager?
    var healthProbes: HealthProbeService?
    var localFacts: (@Sendable () async -> HomeDeviceLiveFacts)?

    init(
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
        localPort: Int = Config.port,
        devices: DeviceRegistry? = nil,
        mtlsClient: (any HomeDeviceProxyClient)? = nil,
        localClient: any HomeDeviceProxyClient = LocalHostProxyClient(),
        vmManager: VMManager? = nil,
        healthProbes: HealthProbeService? = nil,
        localFacts: (@Sendable () async -> HomeDeviceLiveFacts)? = nil,
    ) {
        self.dataDir = dataDir
        self.hostId = hostId
        self.localPort = localPort
        self.devices = devices
        self.mtlsClient = mtlsClient
        self.localClient = localClient
        self.vmManager = vmManager
        self.healthProbes = healthProbes
        self.localFacts = localFacts
    }

    func boot(routes: any RoutesBuilder) throws {
        let home = routes.grouped("api", "home")
        home.get("devices", "health", use: health)
        home.post("placement", "score", use: scorePlacement)
        home.get("devices", use: list)
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE] {
            home.on(method, "devices", ":id", "v1", "**", use: proxy)
        }
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> HomeDeviceList {
        _ = try req.requireUser
        return try await listedDevices(db: req.db)
    }

    @Sendable
    func health(req: Vapor.Request) async throws -> HomeDeviceHealthReport {
        _ = try req.requireUser
        let listed = try await listedDevices(db: req.db)
        return await healthReport(
            listed: listed,
            local: resolvedLocalFacts(db: req.db),
            bearer: req.headers.bearerAuthorization?.token,
        )
    }

    @Sendable
    func scorePlacement(req: Vapor.Request) async throws -> HomePlacementScoreResponse {
        _ = try req.requireUser
        let body = try req.content.decode(HomePlacementScoreRequest.self)
        let listed = try await listedDevices(db: req.db)
        return await scorePlacement(
            request: body,
            listed: listed,
            local: resolvedLocalFacts(db: req.db),
            bearer: req.headers.bearerAuthorization?.token,
        )
    }

    /// Rank Devices from the same probe as health. A down peer is ineligible
    /// and never blocks scoring this Device (PAS-47 / PAS-90).
    func scorePlacement(
        request: HomePlacementScoreRequest,
        listed: HomeDeviceList,
        local: HomeDeviceLiveFacts,
        bearer: String?,
    ) async -> HomePlacementScoreResponse {
        let report = await healthReport(listed: listed, local: local, bearer: bearer)
        return HomePlacementScorer.score(request: request, devices: report.devices)
    }

    /// Probe members in parallel and merge with local facts. Extracted so
    /// tests can cover URL construction, bearer forwarding, and HTTP mapping
    /// without constructing a Vapor `Request`.
    func healthReport(
        listed: HomeDeviceList,
        local: HomeDeviceLiveFacts,
        bearer: String?,
        probeBudgetNanoseconds: UInt64 = HomeDeviceProxy.healthProbeBudgetNanoseconds,
    ) async -> HomeDeviceHealthReport {
        let members = listed.devices.filter { $0.role != "self" }
        let probed = await collectMemberProbes(
            members: members,
            bearer: bearer,
            budgetNanoseconds: probeBudgetNanoseconds,
        )
        return HomeDeviceHealthAggregator.report(listed: listed, local: local, members: probed)
    }

    func collectMemberProbes(
        members: [HomeDevice],
        bearer: String?,
        budgetNanoseconds: UInt64,
    ) async -> [String: HomeDeviceProbeOutcome] {
        var probed: [String: HomeDeviceProbeOutcome] = [:]
        guard !members.isEmpty else { return probed }
        await withTaskGroup(of: (String, HomeDeviceProbeOutcome)?.self) { group in
            for device in members {
                group.addTask {
                    await Optional((device.hostId, self.probeMember(device, bearer: bearer)))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: budgetNanoseconds)
                return nil
            }
            var expired = false
            for await item in group {
                guard let (id, outcome) = item else {
                    expired = true
                    group.cancelAll()
                    continue
                }
                if expired { continue }
                probed[id] = outcome
                if probed.count == members.count {
                    group.cancelAll()
                }
            }
        }
        for device in members where probed[device.hostId] == nil {
            probed[device.hostId] = .failed(.connectTimeout)
        }
        return probed
    }

    private func listedDevices(db: DatabasePool) async throws -> HomeDeviceList {
        let displayName = try await db.read { try DeviceNameSettings.resolved(from: $0) }
        return listedDevices(displayName: displayName)
    }

    private func listedDevices(displayName: String) -> HomeDeviceList {
        HomeDeviceDirectory.list(
            dataDir: dataDir,
            hostId: hostId,
            displayName: displayName,
            devices: devices,
        )
    }

    @Sendable
    func proxy(req: Vapor.Request) async throws -> Response {
        _ = try req.requireUser
        try HomeConsoleProxy.rejectStrippedUpgrade(req)
        let id = try req.parameters.require("id")
        let remainder = req.parameters.getCatchall()
        let path = try HomeDeviceProxy.memberAPIPath(components: remainder)
        let query = req.url.query

        if id == hostId {
            let url = try HomeDeviceProxy.localURL(port: localPort, path: path, query: query)
            return try await forward(req: req, url: url, client: localClient)
        }

        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        let record: DeviceRecord
        do {
            guard let found = try store.record(forHostId: id) else {
                throw BarkVisorError.notFound("Device not found")
            }
            record = found
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .serviceUnavailable,
                reason: "Device registry is unavailable; local runtime continues",
            )
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Device has no reachable address")
        }
        let url = try HomeDeviceProxy.memberURL(
            host: agentHost,
            port: record.agentPort,
            path: path,
            query: query,
        )
        let client: any HomeDeviceProxyClient
        if let mtlsClient {
            client = mtlsClient
        } else {
            do {
                client = try HomeDevicesMTLS.client(dataDir: dataDir, hostId: hostId)
            } catch {
                throw Abort(
                    .serviceUnavailable,
                    reason: "Cannot reach members yet; local runtime continues",
                )
            }
        }
        return try await forward(req: req, url: url, client: client)
    }

    private func forward(
        req: Vapor.Request,
        url: URL,
        client: any HomeDeviceProxyClient,
    ) async throws -> Response {
        let body = try await Self.collectedBody(req)
        var headers: [(String, String)] = []
        if let auth = req.headers.bearerAuthorization {
            headers.append(("Authorization", "Bearer \(auth.token)"))
        }
        if let type = req.headers.contentType {
            headers.append(("Content-Type", type.serialize()))
        }
        if let accept = req.headers.first(name: .accept) {
            headers.append(("Accept", accept))
        }
        headers.append((APIContract.versionHeaderName, String(APIContract.version)))

        var hop = client
        if Self.usesLongMemberTimeout(method: req.method.rawValue, url: url) {
            hop = Self.clientWithTimeout(client, seconds: 90)
        }
        let result: HomeDeviceProxyResponse
        do {
            result = try await hop.send(
                HomeDeviceProxyRequest(
                    method: req.method.rawValue,
                    url: url,
                    headers: headers,
                    body: body,
                ),
            )
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .badGateway,
                reason: HomeDeviceProxyError.classify(error).localizedDescription,
            )
        }
        return Self.response(from: result)
    }

    private static func usesLongMemberTimeout(method: String, url: URL) -> Bool {
        let verb = method.uppercased()
        guard verb == "POST" || verb == "DELETE" else { return false }
        let path = url.path
        return path.contains("/system/interfaces") || path.contains("/system/bridges")
    }

    private static func clientWithTimeout(
        _ client: any HomeDeviceProxyClient,
        seconds: Int64,
    ) -> any HomeDeviceProxyClient {
        if var mtls = client as? AgentMTLSClient {
            mtls.timeoutSeconds = seconds
            return mtls
        }
        if var local = client as? LocalHostProxyClient {
            local.timeout = TimeInterval(seconds)
            return local
        }
        return client
    }

    static func collectedBody(_ req: Vapor.Request) async throws -> Data? {
        let buffer = try await req.body.collect(max: HomeDeviceProxy.maxBodyBytes).get()
        return buffer.map { Data($0.readableBytesView) }
    }

    func resolvedLocalFacts(db: DatabasePool) async -> HomeDeviceLiveFacts {
        if let localFacts {
            return await localFacts()
        }
        let slice = HostInventoryService.metricsSlice(dataDir: dataDir, hostId: hostId)
        var summary: WorkloadHealthSummary?
        if let vmManager {
            do {
                summary = try await Self.localHealthSummary(
                    db: db, vmManager: vmManager, healthProbes: healthProbes,
                )
            } catch {
                // Leave counts unknown. A DB/projection failure must not
                // invent 0 workloads on a reachable Device.
                summary = nil
            }
        }
        let displayName: String
        do {
            displayName = try await db.read { try DeviceNameSettings.resolved(from: $0) }
        } catch {
            displayName = ProcessInfo.processInfo.hostName
        }
        return HomeDeviceLiveFacts(
            displayName: displayName,
            collectedAt: slice.collectedAt,
            platform: HomeDevicePlatformSummary(
                os: PlatformHost.platformName,
                arch: PlatformCapabilities.hostArch,
            ),
            resources: HomeDeviceResourceSummary(
                cpuCount: slice.resources.cpuCount,
                memoryTotalMB: slice.resources.memoryTotalMB,
                memoryUsedMB: slice.resources.memoryUsedMB,
                cpuLoadPercent: slice.resources.cpuLoadPercent,
            ),
            features: HostInventoryService.featureSummary(),
            workloadCount: summary.map(\.items.count),
            healthCounts: summary?.counts,
        )
    }

    static func localHealthSummary(
        db: DatabasePool,
        vmManager: VMManager,
        healthProbes: HealthProbeService?,
    ) async throws -> WorkloadHealthSummary {
        let vms = try await db.read { try VM.fetchAll($0) }
        let lastSeen = try await GuestHealthStore.lastSeen(ids: vms.map(\.id), db: db)
        var items: [WorkloadHealthSummaryItem] = []
        items.reserveCapacity(vms.count)
        for vm in vms {
            let probes = if let healthProbes {
                await healthProbes.results(for: vm)
            } else {
                HealthProbeResults()
            }
            let signals = await vmManager.healthSignals(
                for: vm, lastSeenAt: lastSeen[vm.id], probes: probes,
            )
            let status = WorkloadHealthProjector.project(
                state: VMState.parse(vm.state),
                signals: signals,
                updatedAt: vm.updatedAt,
            )
            items.append(
                WorkloadHealthSummaryItem(
                    id: vm.id,
                    name: vm.name,
                    kind: "vm",
                    health: status.health,
                    lastError: status.lastError,
                ),
            )
        }
        return WorkloadHealthProjector.summarize(
            items: items,
            updatedAt: iso8601.string(from: Date()),
        )
    }

    func probeMember(
        _ device: HomeDevice,
        bearer: String?,
    ) async -> HomeDeviceProbeOutcome {
        guard let agentHost = device.agentHost, !agentHost.isEmpty else {
            return .unreachable("Device has no reachable address")
        }
        let client: any HomeDeviceProxyClient
        if let mtlsClient {
            client = mtlsClient
        } else {
            do {
                client = try HomeDevicesMTLS.client(dataDir: dataDir, hostId: hostId)
            } catch {
                return .unreachable("Cannot reach members yet; local runtime continues")
            }
        }
        let inventoryURL: URL
        let summaryURL: URL
        do {
            inventoryURL = try HomeDeviceProxy.memberURL(
                host: agentHost, port: device.agentPort, path: "/api/agent/inventory",
            )
            summaryURL = try HomeDeviceProxy.memberURL(
                host: agentHost, port: device.agentPort, path: "/api/workloads/health-summary",
            )
        } catch {
            return .unreachable("Device address is not reachable")
        }
        do {
            async let inventoryData = getJSON(url: inventoryURL, client: client, bearer: bearer)
            async let summary = loadMemberHealthSummary(
                url: summaryURL, client: client, bearer: bearer, hostId: device.hostId,
            )
            let inventory = try await HomeDeviceHealthAggregator.decodeInventory(inventoryData)
            return await .ok(HomeDeviceHealthAggregator.facts(from: inventory, summary: summary))
        } catch {
            return .failed(HomeDeviceProxyError.classify(error))
        }
    }

    /// Inventory already succeeded; a missing/broken summary is unknown, not empty-ok.
    func loadMemberHealthSummary(
        url: URL,
        client: any HomeDeviceProxyClient,
        bearer: String?,
        hostId: String,
    ) async -> WorkloadHealthSummary? {
        let summaryData: Data
        do {
            summaryData = try await getJSON(url: url, client: client, bearer: bearer)
        } catch {
            Log.server.warning(
                "Device \(hostId) health-summary fetch failed; treating Workload count as unknown: \(error.localizedDescription)",
            )
            return nil
        }
        do {
            return try HomeDeviceHealthAggregator.decodeHealthSummary(summaryData)
        } catch {
            Log.server.warning(
                "Device \(hostId) health-summary decode failed; treating Workload count as unknown: \(error.localizedDescription)",
            )
            return nil
        }
    }

    private func getJSON(
        url: URL,
        client: any HomeDeviceProxyClient,
        bearer: String?,
    ) async throws -> Data {
        var headers: [(String, String)] = [
            ("Accept", "application/json"),
            (APIContract.versionHeaderName, String(APIContract.version)),
        ]
        if let bearer {
            headers.append(("Authorization", "Bearer \(bearer)"))
        }
        let result = try await client.send(
            HomeDeviceProxyRequest(method: "GET", url: url, headers: headers, body: nil),
        )
        guard (200 ..< 300).contains(result.status) else {
            throw HomeDeviceProxyError.memberHTTP(result.status)
        }
        return result.body
    }

    static func response(from result: HomeDeviceProxyResponse) -> Response {
        let hopByHop: Set = [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailers", "transfer-encoding", "upgrade", "host",
        ]
        var headers = HTTPHeaders()
        for (name, value) in result.headers {
            if hopByHop.contains(name.lowercased()) { continue }
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(
            name: APIContract.versionHeaderName,
            value: String(APIContract.version),
        )
        return Response(
            status: .init(statusCode: result.status),
            headers: headers,
            body: .init(data: result.body),
        )
    }
}
