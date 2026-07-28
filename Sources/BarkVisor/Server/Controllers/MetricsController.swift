import BarkVisorCore
import Foundation
import Vapor

extension SystemStatsSample: Content {}

struct SystemStatsResponse: Content {
    let hostCpuPercent: Double
    let hostMemoryTotalMB: Int
    let hostMemoryUsedMB: Int
    let runningVMs: Int
    let totalVMs: Int
    let vmCpuPercent: Double
    let vmMemoryMB: Int
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
        // VM aggregate from metrics collector
        let samples = await metricsCollector.latestSamples()
        var vmCpu = 0.0
        var vmMem = 0
        for (_, sample) in samples {
            vmCpu += sample.cpuPercent
            vmMem += sample.memoryUsedMB
        }

        let totalVMs = try await req.db.read { db in try VM.fetchCount(db) }
        let runningVMs = await vmState.allRunningVMs().count

        return SystemStatsResponse(
            hostCpuPercent: PlatformHost.cpuLoadPercent,
            hostMemoryTotalMB: PlatformHost.physicalMemoryMB,
            hostMemoryUsedMB: PlatformHost.memoryUsedMB,
            runningVMs: runningVMs,
            totalVMs: totalVMs,
            vmCpuPercent: vmCpu,
            vmMemoryMB: vmMem,
        )
    }

    @Sendable
    func getSystemStatsHistory(req: Vapor.Request) async throws -> [SystemStatsSample] {
        let minutes = min((try? req.query.get(Int.self, at: "minutes")) ?? 30, 1_440)
        return await metricsCollector.recentSystemStats(minutes: minutes)
    }

    @Sendable
    func getMetrics(req: Vapor.Request) async throws -> [MetricSample] {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        guard await vmState.isRunning(id) else {
            throw Abort(.conflict, reason: "VM is not running")
        }

        let minutes = min((try? req.query.get(Int.self, at: "minutes")) ?? 5, 1_440)
        return await metricsCollector.recentSamples(vmID: id, minutes: minutes)
    }

    @Sendable
    func stream(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        guard await vmState.isRunning(id) else {
            throw Abort(.conflict, reason: "VM is not running")
        }

        let metricsStream = await metricsCollector.stream(vmID: id)
        return SSEResponse.stream(from: metricsStream)
    }
}
