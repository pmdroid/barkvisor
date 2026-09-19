import Foundation

enum AMDMetrics {
    static func parseCSV(_ text: String) -> NVIDIAMetrics.Reading {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let first = lines.first else { return .empty }
        let headers = first.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if headers.contains(where: isHeaderRow) {
            return parseHeaderCSV(headers: headers, rows: Array(lines.dropFirst()))
        }
        return NVIDIAMetrics.parseCSV(text)
    }

    static func reading(now: Date = Date()) -> NVIDIAMetrics.Reading {
        cache.reading(now: now, ttl: HostInventoryService.metricsSliceTTL, load: live)
    }

    static func resetCache() {
        cache.reset()
    }

    static func executable() -> URL? {
        #if os(Windows)
            return nil
        #else
            return DockerEngine.which("amd-smi") ?? DockerEngine.which("rocm-smi")
        #endif
    }

    private static func live() -> NVIDIAMetrics.Reading {
        guard let tool = executable() else { return .empty }
        let arguments: [String] = if tool.lastPathComponent.lowercased().contains("amd-smi") {
            ["metric", "--csv"]
        } else {
            ["--csv", "--showuse", "--showtemp"]
        }
        guard let result = try? PlatformProcess.run(
            executable: tool,
            arguments: arguments,
            timeout: 0.8,
        ), result.succeeded else { return .empty }
        return parseCSV(result.stdoutString)
    }

    private static func parseHeaderCSV(headers: [String], rows: [String]) -> NVIDIAMetrics.Reading {
        let utilIndexes = headers.indices.filter { isUtilHeader(headers[$0]) }
        let tempIndexes = headers.indices.filter { isTempHeader(headers[$0]) }
        var utils: [Double] = []
        var temps: [Double] = []
        for row in rows {
            let parts = row.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for index in utilIndexes where index < parts.count {
                if let value = NVIDIAMetrics.parseNumber(parts[index]) {
                    utils.append(min(max(value, 0), 100))
                }
            }
            for index in tempIndexes where index < parts.count {
                if let value = NVIDIAMetrics.parseNumber(parts[index]) {
                    temps.append(value)
                }
            }
        }
        return NVIDIAMetrics.Reading(utilizationPercent: utils.max(), temperatureC: temps.max())
    }

    private static func isHeaderRow(_ header: String) -> Bool {
        isUtilHeader(header) || isTempHeader(header) || header == "device" || header == "gpu"
    }

    private static func isUtilHeader(_ header: String) -> Bool {
        if header.contains("mem") || header.contains("vram") || header.contains("clock")
            || header.contains("freq") {
            return false
        }
        if header.contains("mm") && !header.contains("temp") { return false }
        return header.contains("gfx") || header.contains("activity") || header.contains("busy")
            || (header.contains("use") && (header.contains("gpu") || header.contains("gfx")))
            || header == "gpu use (%)"
    }

    private static func isTempHeader(_ header: String) -> Bool {
        if header.contains("clock") || header.contains("freq") { return false }
        return header.contains("temp") || header.contains("junction") || header.contains("hotspot")
            || header.contains("sensor edge") || header == "edge"
    }
}

private let cache = AMDMetricsCache()

private final class AMDMetricsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (value: NVIDIAMetrics.Reading, expiresAt: Date)?

    func reading(
        now: Date,
        ttl: TimeInterval,
        load: () -> NVIDIAMetrics.Reading,
    ) -> NVIDIAMetrics.Reading {
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
