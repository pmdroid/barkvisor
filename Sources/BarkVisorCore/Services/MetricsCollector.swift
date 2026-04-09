import Darwin
import Foundation
import GRDB

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
/// Guest agent info is persisted to the guest_info DB table.
public actor MetricsCollector {
    private static let maxSamples = 360
    private static let pollInterval: UInt64 = 5_000_000_000 // 5 seconds

    private let dbPool: DatabasePool

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

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

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

    public func stopSystemStatsCollection() {
        systemPollTask?.cancel()
        systemPollTask = nil
    }

    public func recentSystemStats(minutes: Int) -> [SystemStatsSample] {
        let cutoff = iso8601.string(from: Date().addingTimeInterval(TimeInterval(-minutes * 60)))
        return systemStatsBuffer.filter { $0.timestamp >= cutoff }
    }

    private func pollSystemStats() {
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

        // Host CPU via load average
        var loadAvg = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loadAvg, 3)
        var ncpu: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
        let load1m = loadCount >= 1 ? loadAvg[0] : 0.0
        let hostCpuPercent = min(load1m / Double(max(ncpu, 1)) * 100.0, 100.0)

        let sample = SystemStatsSample(
            timestamp: iso8601.string(from: Date()),
            hostCpuPercent: hostCpuPercent,
            hostMemoryUsedMB: hostUsedMB,
            hostMemoryTotalMB: hostTotalMB,
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

        // Remove guest info from DB
        do {
            _ = try dbPool.write { db in
                try GuestInfoRecord.deleteOne(db, key: vmID)
            }
        } catch {
            Log.metrics.error("Failed to remove guest info for VM \(vmID): \(error)", vm: vmID)
        }

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

        let dbPool = dbPool
        let prevDiskReadVal = prevDiskRead[vmID]
        let prevDiskWriteVal = prevDiskWrite[vmID]

        let qmpResult: QMPPollResult = await Task.detached {
            Self.pollQMP(
                qmpSocketPath: qmpSocketPath,
                vmID: vmID,
                dbPool: dbPool,
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

    // MARK: - CPU from macOS process stats

    private func pollCPU(vmID: String, pid: Int32) -> Double {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard ret == size else { return 0 }

        let totalTime = Int64(info.pti_total_user) + Int64(info.pti_total_system)
        let prev = prevCPUTime[vmID] ?? totalTime
        prevCPUTime[vmID] = totalTime

        let delta = totalTime - prev
        // pti_total_user/system are in Mach absolute time units
        // Convert to nanoseconds using timebase
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let deltaNs = Double(delta) * Double(timebase.numer) / Double(timebase.denom)

        // Percentage of one core over the polling interval (5s)
        let percent = deltaNs / Double(5_000_000_000) * 100.0
        return min(max(percent, 0), 100.0)
    }
}
