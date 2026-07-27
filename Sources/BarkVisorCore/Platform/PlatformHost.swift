import Foundation

#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Host CPU and memory metrics with macOS (sysctl/Mach) and Linux (/proc) backends.
public enum PlatformHost {
    /// Logical CPU count.
    public static var cpuCount: Int {
        #if os(macOS)
        var ncpu: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
        return max(Int(ncpu), 1)
        #else
        let n = sysconf(Int32(_SC_NPROCESSORS_ONLN))
        return n > 0 ? Int(n) : max(ProcessInfo.processInfo.processorCount, 1)
        #endif
    }

    /// Total physical memory in bytes.
    public static var physicalMemoryBytes: UInt64 {
        #if os(macOS)
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        return memSize
        #else
        if let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) {
            for line in meminfo.split(separator: "\n") {
                if line.hasPrefix("MemTotal:") {
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    if parts.count >= 2, let kb = UInt64(parts[1]) {
                        return kb * 1_024
                    }
                }
            }
        }
        return ProcessInfo.processInfo.physicalMemory
        #endif
    }

    public static var physicalMemoryMB: Int {
        Int(physicalMemoryBytes / (1_024 * 1_024))
    }

    /// Approximate host memory in use (MB).
    public static var memoryUsedMB: Int {
        #if os(macOS)
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
        #else
        // MemTotal - MemAvailable (fallback: MemFree + Buffers + Cached)
        guard let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
            return 0
        }
        var totalKB: UInt64?
        var availableKB: UInt64?
        var freeKB: UInt64 = 0
        var buffersKB: UInt64 = 0
        var cachedKB: UInt64 = 0
        for line in meminfo.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, let value = UInt64(parts[1]) else { continue }
            switch parts[0] {
            case "MemTotal:": totalKB = value
            case "MemAvailable:": availableKB = value
            case "MemFree:": freeKB = value
            case "Buffers:": buffersKB = value
            case "Cached:": cachedKB = value
            default: break
            }
        }
        guard let total = totalKB else { return 0 }
        let available = availableKB ?? (freeKB + buffersKB + cachedKB)
        let usedKB = total > available ? total - available : 0
        return Int(usedKB / 1_024)
        #endif
    }

    /// Host CPU utilization proxy from 1-minute load average (0…100).
    public static var cpuLoadPercent: Double {
        var loadAvg = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loadAvg, 3)
        let load1m = loadCount >= 1 ? loadAvg[0] : 0.0
        return min(load1m / Double(max(cpuCount, 1)) * 100.0, 100.0)
    }

    /// Human-readable platform name (e.g. "macOS", "Linux").
    public static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "unknown"
        #endif
    }

    /// OS version string from ProcessInfo.
    public static var osVersionString: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
