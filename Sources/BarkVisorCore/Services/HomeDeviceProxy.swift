import Foundation

/// Path rewrite and target checks for `/api/home/devices/{id}/v1/*` (PAS-34).
///
/// Pure so tests do not bind sockets. Reachability is the caller's job;
/// a failed member must not affect local SQLite / QEMU.
public enum HomeDeviceProxy {
    public static let maxBodyBytes = 10_485_760

    public static func memberAPIPath(components: [String]) throws -> String {
        guard !components.isEmpty else {
            throw BarkVisorError.badRequest("Missing member API path")
        }
        for part in components {
            if part.isEmpty || part == "." || part == ".." || part.contains("/")
                || part.contains("\\") {
                throw BarkVisorError.badRequest("Invalid member API path")
            }
        }
        let path = "/api/" + components.joined(separator: "/")
        try rejectNestedHome(path)
        try rejectConsoleLocalOnly(path)
        return path
    }

    public static func memberURL(
        host: String,
        port: Int,
        path: String,
        query: String? = nil,
        scheme: String = "https",
    ) throws -> URL {
        guard (1 ... 65_535).contains(port) else {
            throw BarkVisorError.badRequest("Invalid Device agent port")
        }
        guard let host = PairingPayload.sanitizeProxyHost(host) else {
            throw BarkVisorError.badRequest("Device address is not reachable")
        }
        try rejectNestedHome(path)
        try rejectConsoleLocalOnly(path)
        guard path.hasPrefix("/api/") else {
            throw BarkVisorError.badRequest("Invalid member API path")
        }
        let wrapped = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var raw = "\(scheme)://\(wrapped):\(port)\(path)"
        if let query, !query.isEmpty {
            raw += "?\(query)"
        }
        guard let url = URL(string: raw) else {
            throw BarkVisorError.badRequest("Unable to build Device URL")
        }
        return url
    }

    public static func localURL(
        port: Int,
        path: String,
        query: String? = nil,
    ) throws -> URL {
        try memberURL(host: "127.0.0.1", port: port, path: path, query: query, scheme: "http")
    }

    public static func rejectNestedHome(_ path: String) throws {
        if path == "/api/home" || path.hasPrefix("/api/home/") {
            throw BarkVisorError.badRequest("Home proxy cannot be nested")
        }
    }

    /// Setup and first-run join stay on the host listener. The agent-plane
    /// loopback hop would present `127.0.0.1` and skip the console-local check.
    public static func rejectConsoleLocalOnly(_ path: String) throws {
        if isConsoleLocalOnly(path) {
            throw BarkVisorError.forbidden("Setup and pairing join are limited to this Device")
        }
    }

    public static func isConsoleLocalOnly(_ path: String) -> Bool {
        path == "/api/setup" || path.hasPrefix("/api/setup/")
            || path == "/api/pairing/join" || path.hasPrefix("/api/pairing/join/")
    }
}

/// Outbound request used by the host-API → member mTLS client.
public struct HomeDeviceProxyRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [(String, String)]
    public var body: Data?

    public init(method: String, url: URL, headers: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HomeDeviceProxyResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HomeDeviceProxyClient: Sendable {
    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse
}

public enum HomeDeviceProxyError: Error, LocalizedError, Sendable, Equatable {
    case unreachable(String)
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case let .unreachable(reason):
            "Device is unreachable: \(reason)"
        case .responseTooLarge:
            "Device response is too large"
        }
    }
}
