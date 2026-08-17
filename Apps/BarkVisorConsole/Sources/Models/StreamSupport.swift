import Foundation

/// Serial / VNC are local self-Device streams only. Member Devices wait for PAS-200.
enum WorkloadStream {
    static func isLive(_ state: String) -> Bool {
        state == "running" || state == "stopping"
    }
}

enum WorkloadStreamAccess: Equatable {
    case available
    case memberDisabled
    case notLive

    static func resolve(isSelfDevice: Bool, state: String) -> WorkloadStreamAccess {
        guard isSelfDevice else { return .memberDisabled }
        return WorkloadStream.isLive(state) ? .available : .notLive
    }

    var allowsOpen: Bool { self == .available }

    var reason: String {
        switch self {
        case .available:
            return ""
        case .memberDisabled:
            return "Console and Display on a member Device are not available yet."
        case .notLive:
            return "The Workload must be running."
        }
    }
}

enum StreamReconnect {
    static let maxAttempts = 10
    static let initialDelayNanoseconds: UInt64 = 1_000_000_000
    static let maxDelayNanoseconds: UInt64 = 30_000_000_000
    /// Bound for a VNC "connecting" wait so a missed startVNC/disconnect can retry.
    static let connectTimeoutNanoseconds: UInt64 = 15_000_000_000

    static func shouldRetry(attempt: Int) -> Bool {
        attempt >= 1 && attempt <= maxAttempts
    }

    /// `attempt` is 1-based (first retry after a disconnect).
    static func delayNanoseconds(attempt: Int) -> UInt64 {
        let shift = max(0, attempt - 1)
        let factor: UInt64 = shift >= 63 ? .max : 1 << shift
        let delay = initialDelayNanoseconds &* factor
        return min(delay == 0 ? .max : delay, maxDelayNanoseconds)
    }
}

enum StreamURL {
    static func console(base: URL, workloadID: String, ticket: String) throws -> URL {
        try websocket(base: base, path: "/api/vms/\(workloadID)/console", ticket: ticket)
    }

    static func vnc(base: URL, workloadID: String, ticket: String) throws -> URL {
        try websocket(base: base, path: "/api/vms/\(workloadID)/vnc", ticket: ticket)
    }

    static func websocket(base: URL, path: String, ticket: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw APIError.invalidURL
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let trimmed = path.hasPrefix("/") ? path : "/\(path)"
        components.path = prefix + trimmed
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        components.fragment = nil
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    /// Used by tests to assert a JWT never appears in a stream URL.
    static func containsSecret(_ url: URL, secret: String) -> Bool {
        guard !secret.isEmpty else { return false }
        return url.absoluteString.contains(secret)
    }
}

struct WSTicketRequest: Encodable {
    var vmID: String
}

struct WSTicketResponse: Decodable {
    var ticket: String
}
