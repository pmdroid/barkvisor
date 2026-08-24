import Foundation

#if os(macOS)
    import IOKit
#endif

/// Host GPU busy percent for Device stats. Not IOMMU occupancy (PAS-274/275).
///
/// macOS reads IOAccelerator `PerformanceStatistics`. Linux prefers
/// `gpu_busy_percent` (NVIDIA/AMD), else i915/Xe RC6 residency vs wall time.
public enum PlatformGPU {
    /// 0...100 when a probe exists. Nil when this Device has no readable GPU.
    public static func utilizationPercent(now: Date = Date()) -> Double? {
        #if os(macOS)
            return darwinUtilization()
        #else
            linuxState.lock.lock()
            defer { linuxState.lock.unlock() }
            return linuxBusyPercent(now: now, snapshot: linuxSnapshot(), state: &linuxState.last)
        #endif
    }

    /// Keys IOKit uses on Apple and Intel Macs.
    public static func percent(fromPerformanceStatistics stats: [String: Any]) -> Double? {
        let keys = [
            "Device Utilization %",
            "gpu-busy-percentage",
            "GPU Busy",
            "Renderer Utilization %",
        ]
        for key in keys {
            if let value = number(stats[key]) { return clamp(value) }
        }
        return nil
    }

    public struct LinuxSnapshot: Sendable, Equatable {
        public var gpuBusyPercent: Double?
        public var rc6ResidencyMs: UInt64?
        public var actFreqMHz: Int?

        public init(gpuBusyPercent: Double? = nil, rc6ResidencyMs: UInt64? = nil, actFreqMHz: Int? = nil) {
            self.gpuBusyPercent = gpuBusyPercent
            self.rc6ResidencyMs = rc6ResidencyMs
            self.actFreqMHz = actFreqMHz
        }
    }

    /// Testable i915/AMD/NVIDIA math. First RC6 sample is unknown unless idle.
    public static func linuxBusyPercent(
        now: Date,
        snapshot: LinuxSnapshot,
        state: inout (ms: UInt64, at: Date)?,
    ) -> Double? {
        if let direct = snapshot.gpuBusyPercent { return clamp(direct) }
        if snapshot.actFreqMHz == 0 {
            if let rc6 = snapshot.rc6ResidencyMs {
                state = (rc6, now)
            }
            return 0
        }
        guard let rc6 = snapshot.rc6ResidencyMs else { return nil }
        let previous = state
        state = (rc6, now)
        guard let previous else { return nil }
        let wallMs = now.timeIntervalSince(previous.at) * 1_000
        guard wallMs >= 100 else { return nil }
        guard rc6 >= previous.ms else { return nil }
        let delta = Double(rc6 - previous.ms)
        let idle = min(max(delta / wallMs, 0), 1)
        return clamp((1 - idle) * 100)
    }

    static func linuxSnapshot(fileManager: FileManager = .default) -> LinuxSnapshot {
        var busy: Double?
        var rc6: UInt64?
        var act: Int?
        let drm = "/sys/class/drm"
        let names = (try? fileManager.contentsOfDirectory(atPath: drm)) ?? []
        for name in names.sorted() where isDrmCard(name) {
            let card = drm + "/" + name
            if busy == nil, let raw = readTrimmed(card + "/device/gpu_busy_percent") {
                busy = Double(raw)
            }
            if rc6 == nil, let raw = readTrimmed(card + "/gt/gt0/rc6_residency_ms") {
                rc6 = UInt64(raw)
            }
            if act == nil, let raw = readTrimmed(card + "/gt/gt0/rps_act_freq_mhz") {
                act = Int(raw)
            }
        }
        return LinuxSnapshot(gpuBusyPercent: busy, rc6ResidencyMs: rc6, actFreqMHz: act)
    }

    private static func isDrmCard(_ name: String) -> Bool {
        guard name.hasPrefix("card") else { return false }
        let rest = name.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    private static func readTrimmed(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n
        case let n as Float: return Double(n)
        case let n as Int: return Double(n)
        case let n as Int64: return Double(n)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    #if os(macOS)
        private static func darwinUtilization() -> Double? {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching("IOAccelerator")
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
            else { return nil }
            defer { IOObjectRelease(iterator) }
            var best: Double?
            var service = IOIteratorNext(iterator)
            while service != 0 {
                let current = service
                service = IOIteratorNext(iterator)
                defer { IOObjectRelease(current) }
                if let percent = utilization(forAccelerator: current) {
                    best = max(best ?? 0, percent)
                }
            }
            return best
        }

        private static func utilization(forAccelerator service: io_object_t) -> Double? {
            let key = "PerformanceStatistics" as CFString
            guard let raw = IORegistryEntryCreateCFProperty(
                service, key, kCFAllocatorDefault, 0,
            )?.takeRetainedValue() else { return nil }
            guard let stats = raw as? [String: Any] else { return nil }
            return percent(fromPerformanceStatistics: stats)
        }
    #endif
}

private final class LinuxGPUSampleState: @unchecked Sendable {
    let lock = NSLock()
    var last: (ms: UInt64, at: Date)?
}

private let linuxState = LinuxGPUSampleState()
