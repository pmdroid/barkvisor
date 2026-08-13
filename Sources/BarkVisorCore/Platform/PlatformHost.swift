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

    /// Best-effort host temperature in °C.
    ///
    /// Linux: thermal-zone sysfs (prefers cpu/pkg types). macOS: nil — SMC is
    /// not a public API, and a missing sensor must not be reported as 0°C.
    public static var temperatureCelsius: Double? {
        #if os(Linux)
            linuxThermalCelsius()
        #else
            nil
        #endif
    }

    /// Parse a thermal-zone `temp` file (millidegree C). Returns nil if the
    /// contents are not an integer — never invents 0 for garbage input.
    public static func parseThermalMilliCelsius(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milli = Int(trimmed) else { return nil }
        return Double(milli) / 1_000.0
    }

    /// Pick a thermal zone: prefer cpu/pkg/x86 type names, else the first
    /// parseable reading. Empty / unreadable zones yield nil.
    public static func selectLinuxThermalCelsius(zones: [(type: String, milli: String)]) -> Double? {
        func parsed(_ zone: (type: String, milli: String)) -> Double? {
            parseThermalMilliCelsius(zone.milli)
        }
        func isPreferred(_ name: String) -> Bool {
            let lower = name.lowercased()
            return lower.contains("cpu") || lower.contains("pkg") || lower.contains("x86")
        }
        for zone in zones {
            if isPreferred(zone.type), let value = parsed(zone) { return value }
        }
        for zone in zones {
            if let value = parsed(zone) { return value }
        }
        return nil
    }

    #if os(Linux)
        private static func linuxThermalCelsius() -> Double? {
            let root = "/sys/class/thermal"
            let names = try? FileManager.default.contentsOfDirectory(atPath: root)
            guard let names else { return nil }
            var zones: [(type: String, milli: String)] = []
            for name in names where name.hasPrefix("thermal_zone") {
                let base = "\(root)/\(name)"
                let tempPath = "\(base)/temp"
                guard let milli = try? String(contentsOfFile: tempPath, encoding: .utf8) else {
                    continue
                }
                let typePath = "\(base)/type"
                let rawType = try? String(contentsOfFile: typePath, encoding: .utf8)
                let typ = rawType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                zones.append((typ, milli))
            }
            return selectLinuxThermalCelsius(zones: zones)
        }
    #endif
}
