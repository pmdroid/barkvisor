import Foundation

#if os(macOS)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

public struct HostSensorTemperatures: Sendable, Equatable {
    public var cpuC: Double?
    public var gpuC: Double?
    public var diskC: Double?

    public init(cpuC: Double? = nil, gpuC: Double? = nil, diskC: Double? = nil) {
        self.cpuC = cpuC
        self.gpuC = gpuC
        self.diskC = diskC
    }
}

/// Host CPU and memory metrics with macOS (sysctl/Mach) and Linux (/proc) backends.
public enum PlatformHost {
    /// Logical CPU count.
    public static var cpuCount: Int {
        #if os(macOS)
            var ncpu: Int32 = 0
            var size = MemoryLayout<Int32>.size
            sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
            return max(Int(ncpu), 1)
        #elseif os(Windows)
            let n = Int(GetActiveProcessorCount(WORD(truncatingIfNeeded: ALL_PROCESSOR_GROUPS)))
            return n > 0 ? n : max(ProcessInfo.processInfo.processorCount, 1)
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
        #elseif os(Windows)
            var status = MEMORYSTATUSEX()
            status.dwLength = DWORD(UInt32(MemoryLayout<MEMORYSTATUSEX>.size))
            guard GlobalMemoryStatusEx(&status) else {
                return ProcessInfo.processInfo.physicalMemory
            }
            return UInt64(status.ullTotalPhys)
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
        #elseif os(Windows)
            var status = MEMORYSTATUSEX()
            status.dwLength = DWORD(UInt32(MemoryLayout<MEMORYSTATUSEX>.size))
            guard GlobalMemoryStatusEx(&status) else { return 0 }
            return memoryUsedMB(
                totalBytes: UInt64(status.ullTotalPhys),
                availableBytes: UInt64(status.ullAvailPhys),
            )
        #else
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

    public static func memoryUsedMB(totalBytes: UInt64, availableBytes: UInt64) -> Int {
        let used = totalBytes > availableBytes ? totalBytes - availableBytes : 0
        return Int(used / (1_024 * 1_024))
    }

    public static func fileTimeUInt64(low: UInt32, high: UInt32) -> UInt64 {
        (UInt64(high) << 32) | UInt64(low)
    }

    public static func cpuLoadPercent(
        idleTicks: UInt64,
        kernelTicks: UInt64,
        userTicks: UInt64,
        previousIdleTicks: UInt64,
        previousKernelTicks: UInt64,
        previousUserTicks: UInt64,
    ) -> Double {
        let idle = idleTicks &- previousIdleTicks
        let kernel = kernelTicks &- previousKernelTicks
        let user = userTicks &- previousUserTicks
        let total = kernel &+ user
        guard total > 0 else { return 0 }
        let busy = kernel >= idle ? (kernel - idle) &+ user : user
        return min(Double(busy) / Double(total) * 100.0, 100.0)
    }

    public static var cpuLoadPercent: Double {
        #if os(Windows)
            windowsCpuLoad.publishedPercent()
        #else
            var loadAvg = [Double](repeating: 0, count: 3)
            let loadCount = getloadavg(&loadAvg, 3)
            let load1m = loadCount >= 1 ? loadAvg[0] : 0.0
            return min(load1m / Double(max(cpuCount, 1)) * 100.0, 100.0)
        #endif
    }

    public static func pollCpuLoadPercent() -> Double {
        #if os(Windows)
            windowsCpuLoad.poll()
        #else
            cpuLoadPercent
        #endif
    }

    /// Human-readable platform name (e.g. "macOS", "Linux").
    public static var platformName: String {
        #if os(macOS)
            return "macOS"
        #elseif os(Linux)
            return "Linux"
        #elseif os(Windows)
            return "Windows"
        #else
            return "unknown"
        #endif
    }

    /// OS version string from ProcessInfo.
    public static var osVersionString: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public static var temperatures: HostSensorTemperatures {
        #if os(Linux)
            linuxTemperatures()
        #elseif os(macOS)
            HostSensorTemperatures(gpuC: PlatformGPU.temperatureC())
        #elseif os(Windows)
            HostSensorTemperatures(
                gpuC: NVIDIAMetrics.combine(
                    NVIDIAMetrics.reading().temperatureC,
                    AMDMetrics.reading().temperatureC,
                ),
            )
        #else
            HostSensorTemperatures()
        #endif
    }

    public static var temperatureCelsius: Double? {
        temperatures.cpuC
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

    public enum HwmonKind: Sendable {
        case cpu
        case gpu
        case disk
    }

    public static func hwmonKind(_ name: String) -> HwmonKind? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.contains("nvme") || n == "drivetemp" { return .disk }
        if n.contains("nvidia") || n.contains("amdgpu") || n.contains("nouveau")
            || n == "i915" || n == "xe" || n.contains("radeon") || n.contains("gpu") {
            return .gpu
        }
        if n.contains("coretemp") || n.contains("k10temp") || n.contains("zenpower")
            || n.contains("cpu") || n.contains("soc") {
            return .cpu
        }
        return nil
    }

    public static func pickDiskCelsius(samples: [(label: String, celsius: Double)]) -> Double? {
        if let composite = samples.first(where: { $0.label.lowercased().contains("composite") }) {
            return composite.celsius
        }
        return samples.map(\.celsius).max()
    }

    public static func selectHwmonCelsius(
        chips: [(name: String, samples: [(label: String, milli: String)])],
        kind: HwmonKind,
    ) -> Double? {
        var values: [Double] = []
        for chip in chips {
            guard hwmonKind(chip.name) == kind else { continue }
            if kind == .disk {
                let parsed = chip.samples.compactMap { sample -> (label: String, celsius: Double)? in
                    guard let celsius = parseThermalMilliCelsius(sample.milli) else { return nil }
                    return (sample.label, celsius)
                }
                if let picked = pickDiskCelsius(samples: parsed) {
                    values.append(picked)
                }
            } else {
                for sample in chip.samples {
                    if let celsius = parseThermalMilliCelsius(sample.milli) {
                        values.append(celsius)
                    }
                }
            }
        }
        return values.max()
    }

    #if os(Linux)
        private static func linuxTemperatures() -> HostSensorTemperatures {
            let cpu = linuxThermalCelsius()
            let hwmon = linuxHwmonTemps()
            let nvidia = NVIDIAMetrics.reading().temperatureC
            let amd = AMDMetrics.reading().temperatureC
            return HostSensorTemperatures(
                cpuC: cpu,
                gpuC: NVIDIAMetrics.combine(NVIDIAMetrics.combine(hwmon.gpuC, nvidia), amd),
                diskC: hwmon.diskC,
            )
        }

        private static func linuxHwmonTemps() -> (gpuC: Double?, diskC: Double?) {
            let root = "/sys/class/hwmon"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            var chips: [(name: String, samples: [(label: String, milli: String)])] = []
            for name in names.sorted() {
                let base = "\(root)/\(name)"
                let chipName = (try? String(contentsOfFile: "\(base)/name", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var samples: [(label: String, milli: String)] = []
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                for entry in entries where entry.hasPrefix("temp") && entry.hasSuffix("_input") {
                    guard let milli = try? String(contentsOfFile: "\(base)/\(entry)", encoding: .utf8)
                    else { continue }
                    let labelFile = String(entry.dropLast("_input".count)) + "_label"
                    let label = (try? String(contentsOfFile: "\(base)/\(labelFile)", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    samples.append((label, milli))
                }
                chips.append((chipName, samples))
            }
            return (
                gpuC: selectHwmonCelsius(chips: chips, kind: .gpu),
                diskC: selectHwmonCelsius(chips: chips, kind: .disk),
            )
        }

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

#if os(Windows)
    private final class WindowsCpuLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (idle: UInt64, kernel: UInt64, user: UInt64)?
        private var published: Double = 0

        func publishedPercent() -> Double {
            lock.lock()
            defer { lock.unlock() }
            return published
        }

        func poll() -> Double {
            lock.lock()
            defer { lock.unlock() }
            var idle = FILETIME()
            var kernel = FILETIME()
            var user = FILETIME()
            guard GetSystemTimes(&idle, &kernel, &user) else { return published }
            let idleTicks = PlatformHost.fileTimeUInt64(low: idle.dwLowDateTime, high: idle.dwHighDateTime)
            let kernelTicks = PlatformHost.fileTimeUInt64(low: kernel.dwLowDateTime, high: kernel.dwHighDateTime)
            let userTicks = PlatformHost.fileTimeUInt64(low: user.dwLowDateTime, high: user.dwHighDateTime)
            let previous = last
            last = (idleTicks, kernelTicks, userTicks)
            guard let previous else {
                published = 0
                return 0
            }
            published = PlatformHost.cpuLoadPercent(
                idleTicks: idleTicks,
                kernelTicks: kernelTicks,
                userTicks: userTicks,
                previousIdleTicks: previous.idle,
                previousKernelTicks: previous.kernel,
                previousUserTicks: previous.user,
            )
            return published
        }
    }

    private let windowsCpuLoad = WindowsCpuLoad()
#endif
