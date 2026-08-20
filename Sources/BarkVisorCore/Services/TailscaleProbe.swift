import Foundation

/// Reads Tailscale as an external dependency (PAS-89). Never vendors the binary.
public enum TailscaleProbe {
    public static let cacheTTL: TimeInterval = 30

    public static let candidatePaths = [
        "/usr/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    public struct Runner: Sendable {
        public var executablePath: String?
        public var invoke: @Sendable (String, [String]) throws -> CommandResult

        public init(
            executablePath: String?,
            invoke: @escaping @Sendable (String, [String]) throws -> CommandResult,
        ) {
            self.executablePath = executablePath
            self.invoke = invoke
        }

        public static let live = Runner(executablePath: nil) { path, args in
            try PlatformProcess.run(path: path, arguments: args, timeout: 2)
        }
    }

    /// Live detect with a short process-lifetime cache. Tests pass a `Runner`.
    public static func detect(
        runner: Runner = .live,
        now: Date = Date(),
        useCache: Bool = true,
    ) -> TailnetInfo {
        if useCache, runner.executablePath == nil {
            if let cached = cache.load(now: now) {
                return cached
            }
        }
        let info = probe(runner: runner)
        if useCache, runner.executablePath == nil {
            cache.store(info, now: now)
        }
        return info
    }

    public static func resetCache() {
        cache.reset()
    }

    public static func findExecutable() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func parseIPv4Output(_ stdout: String) -> String? {
        let line = stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard PairingPayload.sanitizeHost(line) == line else { return nil }
        guard line.contains("."), !line.contains(":") else { return nil }
        return line
    }

    public static func parseStatusJSON(_ stdout: String) -> (ip: String?, dnsName: String?) {
        guard let data = stdout.data(using: .utf8),
              let status = try? JSONDecoder().decode(StatusJSON.self, from: data)
        else {
            return (nil, nil)
        }
        var dns = status.node?.dnsName?.trimmingCharacters(in: .whitespacesAndNewlines)
        while let current = dns, current.hasSuffix(".") {
            dns = String(current.dropLast())
        }
        if let current = dns, current.isEmpty || PairingPayload.sanitizeHost(current) == nil {
            dns = nil
        }
        let ip = status.node?.tailscaleIPs?
            .compactMap(parseIPv4Output)
            .first
        return (ip, dns)
    }

    private static func probe(runner: Runner) -> TailnetInfo {
        let path = runner.executablePath ?? findExecutable()
        guard let path else { return .unavailable }
        let ipOut = try? runner.invoke(path, ["ip", "-4"])
        var ip = ipOut.flatMap { $0.succeeded ? parseIPv4Output($0.stdoutString) : nil }
        let statusOut = try? runner.invoke(path, ["status", "--json"])
        let parsed = statusOut.flatMap { $0.succeeded ? parseStatusJSON($0.stdoutString) : nil }
        if ip == nil {
            ip = parsed?.ip
        }
        let dns = parsed?.dnsName
        guard let ip else {
            return TailnetInfo(available: false, ip: nil, dnsName: dns)
        }
        return TailnetInfo(available: true, ip: ip, dnsName: dns)
    }

    private static let cache = ProbeCache()

    private struct StatusJSON: Decodable {
        var node: Node?
        enum CodingKeys: String, CodingKey {
            case node = "Self"
        }

        struct Node: Decodable {
            var dnsName: String?
            var tailscaleIPs: [String]?
            enum CodingKeys: String, CodingKey {
                case dnsName = "DNSName"
                case tailscaleIPs = "TailscaleIPs"
            }
        }
    }
}

private final class ProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (info: TailnetInfo, expiresAt: Date)?

    func load(now: Date) -> TailnetInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let value, value.expiresAt > now else { return nil }
        return value.info
    }

    func store(_ info: TailnetInfo, now: Date) {
        lock.lock()
        value = (info, now.addingTimeInterval(TailscaleProbe.cacheTTL))
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
