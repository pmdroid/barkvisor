#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

public struct MetricSample: Codable, Sendable {
    public let timestamp: String
    public let cpuPercent: Double
    public let memoryUsedMB: Int
    public let diskReadBytes: Int64
    public let diskWriteBytes: Int64

    public init(
        timestamp: String,
        cpuPercent: Double,
        memoryUsedMB: Int,
        diskReadBytes: Int64,
        diskWriteBytes: Int64,
    ) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memoryUsedMB = memoryUsedMB
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }
}

public struct SystemStatsSample: Codable, Sendable {
    public let timestamp: String
    public let hostCpuPercent: Double
    public let hostMemoryUsedMB: Int
    public let hostMemoryTotalMB: Int

    public init(
        timestamp: String, hostCpuPercent: Double, hostMemoryUsedMB: Int, hostMemoryTotalMB: Int,
    ) {
        self.timestamp = timestamp
        self.hostCpuPercent = hostCpuPercent
        self.hostMemoryUsedMB = hostMemoryUsedMB
        self.hostMemoryTotalMB = hostMemoryTotalMB
    }
}

struct QMPPollResult {
    let memoryUsedMB: Int
    let diskRead: Int64
    let diskWrite: Int64
    let newTotalRead: Int64?
    let newTotalWrite: Int64?
}

/// Per-VM metrics polling via QMP, stores samples in a ring buffer (30 min history at 5s interval = 360 samples)
/// Also collects host-level CPU/memory stats on a separate timer for the dashboard history.
/// QMP here is balloon + blockstats only; qemu-guest-agent inventory is `GuestAgentInventory`.
///
/// Host history (`GET /api/system/stats/history`) is this in-memory ring only
/// (PAS-85). There is no TSDB. `minutes` is clamped to
/// `systemStatsRetentionMinutes` (30) — the API used to accept 1440 but the
/// buffer cannot retain that long.
public actor MetricsCollector {
    public static let systemStatsMaxSamples = 360
    public static let systemStatsPollIntervalSeconds = 5
    /// 360 samples × 5s = 30 minutes. Clients must not assume a longer window.
    public static let systemStatsRetentionMinutes =
        (systemStatsMaxSamples * systemStatsPollIntervalSeconds) / 60

    /// Clamp `?minutes=` for host history. Default and ceiling are the ring
    /// length; values below 1 become 1.
    public static func clampSystemStatsMinutes(_ requested: Int) -> Int {
        min(max(requested, 1), systemStatsRetentionMinutes)
    }

    private static let maxSamples = systemStatsMaxSamples
    private static let pollInterval = UInt64(systemStatsPollIntervalSeconds) * 1_000_000_000

    private var buffers: [String: [MetricSample]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var continuations: [String: [String: AsyncStream<MetricSample>.Continuation]] = [:]

    // Previous values for delta computation
    private var prevDiskRead: [String: Int64] = [:]
    private var prevDiskWrite: [String: Int64] = [:]
    private var prevCPUTime: [String: Int64] = [:]

    // System-level stats ring buffer
    private var systemStatsBuffer: [SystemStatsSample] = []
    private var systemPollTask: Task<Void, Never>?

    public init() {}

    /// Start collecting host-level stats (call once at server startup)
    public func startSystemStatsCollection() {
        guard systemPollTask == nil else { return }
        systemPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    await self.pollSystemStats()
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    public func recentSystemStats(minutes: Int) -> [SystemStatsSample] {
        let cutoff = iso8601.string(from: Date().addingTimeInterval(TimeInterval(-minutes * 60)))
        return systemStatsBuffer.filter { $0.timestamp >= cutoff }
    }

    private func pollSystemStats() {
        let sample = SystemStatsSample(
            timestamp: iso8601.string(from: Date()),
            hostCpuPercent: PlatformHost.cpuLoadPercent,
            hostMemoryUsedMB: PlatformHost.memoryUsedMB,
            hostMemoryTotalMB: PlatformHost.physicalMemoryMB,
        )

        systemStatsBuffer.append(sample)
        if systemStatsBuffer.count > Self.maxSamples {
            systemStatsBuffer.removeFirst(systemStatsBuffer.count - Self.maxSamples)
        }
    }

    public func start(vmID: String, qmpSocketPath: String, pid: Int32) {
        guard tasks[vmID] == nil else { return }

        buffers[vmID] = []
        let task = Task { [weak self] in
            // Wait for QMP socket to be ready
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            while !Task.isCancelled {
                if let self {
                    await poll(vmID: vmID, qmpSocketPath: qmpSocketPath, pid: pid)
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
        tasks[vmID] = task
    }

    public func stop(vmID: String) {
        tasks[vmID]?.cancel()
        tasks.removeValue(forKey: vmID)
        buffers.removeValue(forKey: vmID)
        prevDiskRead.removeValue(forKey: vmID)
        prevDiskWrite.removeValue(forKey: vmID)
        prevCPUTime.removeValue(forKey: vmID)

        // Close all SSE streams
        if let conts = continuations[vmID] {
            for (_, cont) in conts {
                cont.finish()
            }
        }
        continuations.removeValue(forKey: vmID)
    }

    public func recentSamples(vmID: String, minutes: Int) -> [MetricSample] {
        guard let buffer = buffers[vmID] else { return [] }
        let cutoff = iso8601.string(from: Date().addingTimeInterval(TimeInterval(-minutes * 60)))
        return buffer.filter { $0.timestamp >= cutoff }
    }

    /// Latest sample per VM, for aggregate dashboard
    public func latestSamples() -> [String: MetricSample] {
        var result: [String: MetricSample] = [:]
        for (vmID, buffer) in buffers {
            if let last = buffer.last { result[vmID] = last }
        }
        return result
    }

    public func stream(vmID: String) -> AsyncStream<MetricSample> {
        let vmIDCopy = vmID
        let contID = UUID().uuidString
        return AsyncStream { continuation in
            self.continuations[vmIDCopy, default: [:]][contID] = continuation

            // Clean up when the client disconnects
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(vmID: vmIDCopy, id: contID)
                }
            }
        }
    }

    private func removeContinuation(vmID: String, id: String) {
        continuations[vmID]?.removeValue(forKey: id)
        if continuations[vmID]?.isEmpty == true {
            continuations.removeValue(forKey: vmID)
        }
    }

    private func poll(vmID: String, qmpSocketPath: String, pid: Int32) async {
        guard tasks[vmID] != nil else { return }

        let cpuPercent = pollCPU(vmID: vmID, pid: pid)

        let prevDiskReadVal = prevDiskRead[vmID]
        let prevDiskWriteVal = prevDiskWrite[vmID]

        let qmpResult: QMPPollResult = await Task.detached {
            Self.pollQMP(
                qmpSocketPath: qmpSocketPath,
                prevDiskReadVal: prevDiskReadVal,
                prevDiskWriteVal: prevDiskWriteVal,
            )
        }.value

        if let newRead = qmpResult.newTotalRead {
            prevDiskRead[vmID] = newRead
        }
        if let newWrite = qmpResult.newTotalWrite {
            prevDiskWrite[vmID] = newWrite
        }

        let sample = MetricSample(
            timestamp: iso8601.string(from: Date()),
            cpuPercent: cpuPercent,
            memoryUsedMB: qmpResult.memoryUsedMB,
            diskReadBytes: qmpResult.diskRead,
            diskWriteBytes: qmpResult.diskWrite,
        )

        buffers[vmID, default: []].append(sample)
        if let count = buffers[vmID]?.count, count > Self.maxSamples {
            buffers[vmID]?.removeFirst(count - Self.maxSamples)
        }

        if let conts = continuations[vmID] {
            for (_, cont) in conts {
                cont.yield(sample)
            }
        }
    }

    // MARK: - Per-process CPU

    private func pollCPU(vmID: String, pid: Int32) -> Double {
        #if os(macOS)
            var info = proc_taskinfo()
            let size = MemoryLayout<proc_taskinfo>.size
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
            guard ret == size else { return 0 }

            let totalTime = Int64(info.pti_total_user) + Int64(info.pti_total_system)
            let prev = prevCPUTime[vmID] ?? totalTime
            prevCPUTime[vmID] = totalTime

            let delta = totalTime - prev
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let deltaNs = Double(delta) * Double(timebase.numer) / Double(timebase.denom)
            let percent = deltaNs / Double(5_000_000_000) * 100.0
            return min(max(percent, 0), 100.0)
        #else
            // Linux: /proc/<pid>/stat fields utime+stime in clock ticks
            guard let content = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else {
                return 0
            }
            guard let rparen = content.lastIndex(of: ")") else { return 0 }
            let rest = content[content.index(after: rparen)...].split(separator: " ")
            // rest[0]=state (field 3); utime field 14 => index 11; stime field 15 => index 12
            guard rest.count > 12,
                  let utime = Int64(rest[11]),
                  let stime = Int64(rest[12])
            else { return 0 }
            let totalTime = utime + stime
            let prev = prevCPUTime[vmID] ?? totalTime
            prevCPUTime[vmID] = totalTime
            let delta = Double(totalTime - prev)
            let ticks = Double(sysconf(Int32(_SC_CLK_TCK)))
            guard ticks > 0 else { return 0 }
            let percent = (delta / ticks) / 5.0 * 100.0
            return min(max(percent, 0), 100.0)
        #endif
    }
}
