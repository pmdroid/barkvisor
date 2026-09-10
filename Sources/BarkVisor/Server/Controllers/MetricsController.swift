import BarkVisorCore
import Foundation
import Vapor

extension SystemStatsSample: Content {}
extension HostMetrics: Content {}

/// Compatible `/api/system/stats` payload (PAS-85).
///
/// Existing SPA fields (`hostCpuPercent`, memory, VM aggregates) stay put.
/// `metrics` is the unified `HostMetrics` DTO; CPU/mem there are the same
/// live `PlatformHost` probes as the top-level host* fields (not a full
/// inventory snapshot). Disk/net rate samples are not included (optional later).
struct SystemStatsResponse: Content {
    let hostCpuPercent: Double
    let hostMemoryTotalMB: Int
    let hostMemoryUsedMB: Int
    let runningVMs: Int
    let totalVMs: Int
    let vmCpuPercent: Double
    let vmMemoryMB: Int
    let appCpuPercent: Double
    let appMemoryMB: Int
    let appNetworkRxBytes: Int64
    let appNetworkTxBytes: Int64
    let runningApps: Int
    let totalApps: Int
    let metrics: HostMetrics
    let historyRetentionMinutes: Int
    let historySampleIntervalSeconds: Int
}

struct MetricsController: RouteCollection {
    let vmState: any VMStateQuerying
    let metricsCollector: MetricsCollector

    func boot(routes: any RoutesBuilder) throws {
        let metrics = routes.grouped("api", "vms", ":id", "metrics")
        metrics.get(use: getMetrics)
        metrics.get("stream", use: stream)

        // System-wide stats
        routes.get("api", "system", "stats", use: getSystemStats)
        routes.get("api", "system", "stats", "history", use: getSystemStatsHistory)
    }

    @Sendable
    func getSystemStats(req: Vapor.Request) async throws -> SystemStatsResponse {
        let samples = await metricsCollector.latestSamples()
        let workloads = try await req.db.read { db in try VM.fetchAll(db) }
        let appIDs = Set(workloads.filter(\.isApplication).map(\.id))
        let split = MetricsAggregation.split(samples: samples, appIDs: appIDs)

        let totalVMs = try await req.db.read { db in try VM.fetchCount(db) }
        let runningVMs = await vmState.allRunningVMs().count
        let totalApps = appIDs.count
        let runningApps = workloads.filter { $0.isApplication && $0.state == "running" }.count

        let metrics = HostMetrics.live()

        return SystemStatsResponse(
            hostCpuPercent: metrics.cpuLoadPercent,
            hostMemoryTotalMB: metrics.memoryTotalMB,
            hostMemoryUsedMB: metrics.memoryUsedMB,
            runningVMs: runningVMs,
            totalVMs: totalVMs,
            vmCpuPercent: split.vmCpuPercent,
            vmMemoryMB: split.vmMemoryMB,
            appCpuPercent: split.appCpuPercent,
            appMemoryMB: split.appMemoryMB,
            appNetworkRxBytes: split.appNetworkRxBytes,
            appNetworkTxBytes: split.appNetworkTxBytes,
            runningApps: runningApps,
            totalApps: totalApps,
            metrics: metrics,
            historyRetentionMinutes: MetricsCollector.systemStatsRetentionMinutes,
            historySampleIntervalSeconds: MetricsCollector.systemStatsPollIntervalSeconds,
        )
    }

    @Sendable
    func getSystemStatsHistory(req: Vapor.Request) async throws -> [SystemStatsSample] {
        let requested =
            (try? req.query.get(Int.self, at: "minutes")) ?? MetricsCollector.systemStatsRetentionMinutes
        let minutes = MetricsCollector.clampSystemStatsMinutes(requested)
        return await metricsCollector.recentSystemStats(minutes: minutes)
    }

    @Sendable
    func getMetrics(req: Vapor.Request) async throws -> [MetricSample] {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        guard await isMetricsAvailable(id, req: req) else {
            throw Abort(.conflict, reason: "VM is not running")
        }

        let minutes = min((try? req.query.get(Int.self, at: "minutes")) ?? 5, 1_440)
        return await metricsCollector.recentSamples(vmID: id, minutes: minutes)
    }

    @Sendable
    func stream(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        guard await isMetricsAvailable(id, req: req) else {
            throw Abort(.conflict, reason: "VM is not running")
        }

        let metricsStream = await metricsCollector.stream(vmID: id)
        return SSEResponse.stream(from: metricsStream)
    }

    private func isMetricsAvailable(_ id: String, req: Vapor.Request) async -> Bool {
        if await vmState.isRunning(id) { return true }
        guard let vm = try? await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            return false
        }
        return vm.isApplication && vm.state == "running"
    }
}
