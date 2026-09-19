import Foundation

enum NVIDIAMetrics {
    struct Reading: Equatable {
        var utilizationPercent: Double?
        var temperatureC: Double?

        static let empty = Reading(utilizationPercent: nil, temperatureC: nil)
    }

    static func parseCSV(_ text: String) -> Reading {
        var utils: [Double] = []
        var temps: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !parts.isEmpty else { continue }
            if let util = parseNumber(parts[0]) {
                utils.append(min(max(util, 0), 100))
            }
            if parts.count > 1, let temp = parseNumber(parts[1]) {
                temps.append(temp)
            }
        }
        return Reading(utilizationPercent: utils.max(), temperatureC: temps.max())
    }

    static func combine(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    static func reading(now: Date = Date()) -> Reading {
        cache.reading(now: now, ttl: HostInventoryService.metricsSliceTTL, load: live)
    }

    static func resetCache() {
        cache.reset()
    }

    static func executable() -> URL? {
        #if os(Windows)
            let candidates = [
                "C:\\Windows\\System32\\nvidia-smi.exe",
                "C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe",
            ]
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return nil
        #else
            return DockerEngine.which("nvidia-smi")
        #endif
    }

    static func parseNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lower = trimmed.lowercased()
        if lower == "n/a" || lower == "[n/a]" { return nil }
        var num = ""
        var sawDot = false
        for ch in trimmed {
            if ch.isNumber {
                num.append(ch)
            } else if ch == ".", !sawDot {
                num.append(ch)
                sawDot = true
            } else if !num.isEmpty {
                break
            }
        }
        return Double(num)
    }

    private static func live() -> Reading {
        guard let smi = executable() else { return .empty }
        guard let result = try? PlatformProcess.run(
            executable: smi,
            arguments: [
                "--query-gpu=utilization.gpu,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
            timeout: 2,
        ), result.succeeded else { return .empty }
        return parseCSV(result.stdoutString)
    }
}

private let cache = NVIDIAMetricsCache()

private final class NVIDIAMetricsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (value: NVIDIAMetrics.Reading, expiresAt: Date)?

    func reading(now: Date, ttl: TimeInterval, load: () -> NVIDIAMetrics.Reading) -> NVIDIAMetrics.Reading {
        lock.lock()
        if let cached, cached.expiresAt > now {
            let value = cached.value
            lock.unlock()
            return value
        }
        lock.unlock()
        let value = load()
        lock.lock()
        cached = (value, now.addingTimeInterval(ttl))
        lock.unlock()
        return value
    }

    func reset() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
