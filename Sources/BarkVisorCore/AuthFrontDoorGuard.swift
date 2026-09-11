import Foundation

public enum AuthFrontDoorDecision: Equatable, Sendable {
    case allow
    case rejectHost
    case rejectOrigin
}

public enum AuthFrontDoorGuard: Sendable {
    public static let loopbackHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
        "[::1]",
        "0:0:0:0:0:0:0:1",
    ]

    public static let mutatingMethods: Set<String> = ["POST", "PUT", "PATCH", "DELETE"]

    public static func stripMappedIPv4(_ ip: String) -> String {
        var value = ip
        if value.hasPrefix("::ffff:") {
            value = String(value.dropFirst(7))
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    public static func isLoopbackPeer(_ ip: String?) -> Bool {
        guard let ip, !ip.isEmpty else { return false }
        let stripped = stripMappedIPv4(ip).lowercased()
        return loopbackHosts.contains(stripped) || stripped == "localhost"
    }

    public static func normalizedHost(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("[") {
            if let end = value.firstIndex(of: "]") {
                return String(value[value.index(after: value.startIndex) ..< end])
            }
        }
        if value.count(where: { $0 == ":" }) == 1, let colon = value.lastIndex(of: ":") {
            return String(value[..<colon])
        }
        return value
    }

    public static func hostIsAllowed(_ hostHeader: String, extras: Set<String>) -> Bool {
        let host = normalizedHost(hostHeader)
        if loopbackHosts.contains(host) { return true }
        if extras.contains(host) { return true }
        return false
    }

    public static func originIsAllowed(_ origin: String, extras: Set<String>) -> Bool {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return false }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return false
        }
        return hostIsAllowed(host, extras: extras)
    }

    public static func evaluate(
        host: String?,
        origin: String?,
        method: String,
        extras: Set<String>,
    ) -> AuthFrontDoorDecision {
        guard let host, !host.isEmpty, hostIsAllowed(host, extras: extras) else {
            return .rejectHost
        }
        let verb = method.uppercased()
        if mutatingMethods.contains(verb) {
            if let origin, !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !originIsAllowed(origin, extras: extras) {
                    return .rejectOrigin
                }
            }
        }
        return .allow
    }

    public static func configuredHosts(
        hostname: String = ProcessInfo.processInfo.hostName,
        interfaces: [HostInterfaceInfo] = HostInfoService.listInterfaces(),
    ) -> Set<String> {
        var hosts: Set<String> = []
        let hn = hostname.lowercased()
        if !hn.isEmpty {
            hosts.insert(hn)
            if let short = hn.split(separator: ".").first {
                hosts.insert(String(short))
            }
        }
        for iface in interfaces {
            let ip = stripMappedIPv4(iface.ipAddress).lowercased()
            if !ip.isEmpty {
                hosts.insert(ip)
            }
        }
        return hosts
    }
}
