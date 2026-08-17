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
    func list(req: Vapor.Request) throws -> HomeDeviceList {
        _ = try req.requireUser
        return listedDevices()
    }

    @Sendable
    func health(req: Vapor.Request) async throws -> HomeDeviceHealthReport {
        _ = try req.requireUser
        return await healthReport(
            listed: listedDevices(),
            local: resolvedLocalFacts(db: req.db),
            bearer: req.headers.bearerAuthorization?.token,
        )
    }

    @Sendable
    func scorePlacement(req: Vapor.Request) async throws -> HomePlacementScoreResponse {
        _ = try req.requireUser
        let body = try req.content.decode(HomePlacementScoreRequest.self)
        return await scorePlacement(
            request: body,
            listed: listedDevices(),
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
    ) async -> HomeDeviceHealthReport {
        let members = listed.devices.filter { $0.role != "self" }
        var probed: [String: HomeDeviceProbeOutcome] = [:]
        await withTaskGroup(of: (String, HomeDeviceProbeOutcome).self) { group in
            for device in members {
                group.addTask {
                    await (device.hostId, self.probeMember(device, bearer: bearer))
                }
            }
            for await (id, result) in group {
                probed[id] = result
            }
        }
        return HomeDeviceHealthAggregator.report(listed: listed, local: local, members: probed)
    }

    private func listedDevices() -> HomeDeviceList {
        HomeDeviceDirectory.list(
            dataDir: dataDir,
            hostId: hostId,
            displayName: ProcessInfo.processInfo.hostName,
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
                    reason: "This Device cannot reach members yet; local runtime continues",
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

        let result: HomeDeviceProxyResponse
        do {
            result = try await client.send(
                HomeDeviceProxyRequest(
                    method: req.method.rawValue,
                    url: url,
                    headers: headers,
                    body: body,
                ),
            )
        } catch let error as HomeDeviceProxyError {
            throw Abort(.badGateway, reason: error.localizedDescription)
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .badGateway,
                reason: "Device is unreachable: \(error.localizedDescription)",
            )
        }
        return Self.response(from: result)
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
        return HomeDeviceLiveFacts(
            displayName: ProcessInfo.processInfo.hostName,
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
            features: HomeDeviceFeatureSummary(
                kvmDevice: HostInventoryService.kvmDevicePresent(),
                bridgedNetworking: HostInventoryService.bridgedNetworkingSupported(
                    platformSupports: PlatformCapabilities.supportsBridgedNetworking,
                    qemuBridgeHelper: HostInventoryService.qemuBridgeHelperPresent(),
                    os: PlatformHost.platformName,
                ),
                usbPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            ),
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
                return .unreachable("This Device cannot reach members yet; local runtime continues")
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
            let inventoryData = try await getJSON(url: inventoryURL, client: client, bearer: bearer)
            let inventory = try HomeDeviceHealthAggregator.decodeInventory(inventoryData)
            let summary = await loadMemberHealthSummary(
                url: summaryURL, client: client, bearer: bearer, hostId: device.hostId,
            )
            return .ok(HomeDeviceHealthAggregator.facts(from: inventory, summary: summary))
        } catch let error as HomeDeviceProxyError {
            return .unreachable(error.localizedDescription)
        } catch {
            return .unreachable("Device is unreachable: \(error.localizedDescription)")
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
            throw HomeDeviceProxyError.unreachable("member returned HTTP \(result.status)")
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
