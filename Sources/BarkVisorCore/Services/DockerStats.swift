import Foundation

public struct DockerStatsSample: Sendable, Equatable {
    public var name: String
    public var cpuPercent: Double
    public var memoryUsedBytes: Int64
    public var memoryLimitBytes: Int64
    public var networkRxBytes: Int64
    public var networkTxBytes: Int64

    public init(
        name: String,
        cpuPercent: Double,
        memoryUsedBytes: Int64,
        memoryLimitBytes: Int64,
        networkRxBytes: Int64,
        networkTxBytes: Int64,
    ) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
    }
}

public struct DockerStatsTotals: Sendable, Equatable {
    public var containerCount: Int
    public var cpuPercent: Double
    public var memoryUsedBytes: Int64
    public var memoryLimitBytes: Int64
    public var networkRxBytes: Int64
    public var networkTxBytes: Int64

    public init(
        containerCount: Int,
        cpuPercent: Double,
        memoryUsedBytes: Int64,
        memoryLimitBytes: Int64,
        networkRxBytes: Int64,
        networkTxBytes: Int64,
    ) {
        self.containerCount = containerCount
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
    }

    public static let empty = DockerStatsTotals(
        containerCount: 0,
        cpuPercent: 0,
        memoryUsedBytes: 0,
        memoryLimitBytes: 0,
        networkRxBytes: 0,
        networkTxBytes: 0,
    )
}

public enum DockerStats {
    public static func snapshot(id: String, project: String) -> DockerStatsTotals? {
        guard let ids = try? ComposeRuntime.containerIDs(id: id, project: project),
              !ids.isEmpty else { return nil }
        guard let result = try? DockerCLI.run(
            arguments: ["stats", "--no-stream", "--format", "json"] + ids,
            timeout: 20,
        ), result.succeeded else { return nil }
        let samples = parse(output: result.stdoutString)
        guard !samples.isEmpty else { return nil }
        return totals(samples)
    }

    public static func parse(output: String) -> [DockerStatsSample] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> DockerStatsSample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["Name"] as? String,
              !name.isEmpty else { return nil }
        let memory = parsePair(json["MemUsage"] as? String)
        let net = parsePair(json["NetIO"] as? String)
        return DockerStatsSample(
            name: name,
            cpuPercent: parsePercent(json["CPUPerc"] as? String),
            memoryUsedBytes: memory.0,
            memoryLimitBytes: memory.1,
            networkRxBytes: net.0,
            networkTxBytes: net.1,
        )
    }

    public static func totals(_ samples: [DockerStatsSample]) -> DockerStatsTotals {
        DockerStatsTotals(
            containerCount: samples.count,
            cpuPercent: samples.reduce(0) { $0 + $1.cpuPercent },
            memoryUsedBytes: samples.reduce(0) { $0 + $1.memoryUsedBytes },
            memoryLimitBytes: samples.reduce(0) { $0 + $1.memoryLimitBytes },
            networkRxBytes: samples.reduce(0) { $0 + $1.networkRxBytes },
            networkTxBytes: samples.reduce(0) { $0 + $1.networkTxBytes },
        )
    }

    static func parsePercent(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard let value = Double(cleaned), value.isFinite else { return 0 }
        return max(value, 0)
    }

    static func parsePair(_ raw: String?) -> (Int64, Int64) {
        guard let raw else { return (0, 0) }
        let parts = raw.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2 else { return (0, 0) }
        return (parseBytes(parts[0]), parseBytes(parts[1]))
    }

    public static func parseBytes(_ raw: String) -> Int64 {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "--" || cleaned == "—" { return 0 }
        var digits = ""
        var rest = cleaned[...]
        while let first = rest.first, first.isNumber || first == "." {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard let value = Double(digits), value.isFinite else { return 0 }
        let unit = rest.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Int64((value * multiplier(for: unit)).rounded())
    }

    static func multiplier(for unit: String) -> Double {
        switch unit {
        case "", "B": 1
        case "KB", "KILOBYTE", "KILOBYTES": 1_000
        case "MB": 1_000_000
        case "GB": 1_000_000_000
        case "TB": 1_000_000_000_000
        case "K", "KIB": 1_024
        case "M", "MIB": 1_048_576
        case "G", "GIB": 1_073_741_824
        case "T", "TIB": 1_099_511_627_776
        default: 1
        }
    }
}
