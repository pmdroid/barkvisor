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
        // Host memory from sysctl
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        let hostTotalMB = Int(memSize / (1_024 * 1_024))

        // Host memory used from vm_statistics64
        let hostUsedMB: Int = {
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64>.size / MemoryLayout<natural_t>.size,
            )
            let hostPort = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, hostPort) }
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            let pageSize = UInt64(sysconf(_SC_PAGESIZE))
            let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
            return Int(used / (1_024 * 1_024))
        }()

        // Host CPU from host_processor_info (percentage of all cores)
        // Simplified: use load average as a proxy
        var loadAvg = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loadAvg, 3)
        var ncpu: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
        let load1m = loadCount >= 1 ? loadAvg[0] : 0.0
        let hostCpuPercent = min(load1m / Double(max(ncpu, 1)) * 100.0, 100.0)

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
            hostCpuPercent: hostCpuPercent,
            hostMemoryTotalMB: hostTotalMB,
            hostMemoryUsedMB: hostUsedMB,
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
