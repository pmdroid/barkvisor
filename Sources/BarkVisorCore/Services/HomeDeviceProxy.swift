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
            try rejectPathSegment(part)
        }
        let path = "/api/" + components.joined(separator: "/")
        try rejectNestedHome(path)
        try rejectConsoleLocalOnly(path)
        try rejectLibraryBytes(path)
        return path
    }

    /// Decode percent-encoded segments and reject `.` / `..` so
    /// console-local guards do not depend on router or client
    /// path normalization. Encoded slashes stay a single segment
    /// and are rejected the same way as ``memberAPIPath``.
    public static func normalizedAPIPath(_ raw: String) throws -> String {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let decoded: [String] = try parts.map { part in
            guard let value = part.removingPercentEncoding else {
                throw BarkVisorError.badRequest("Invalid member API path")
            }
            try rejectPathSegment(value)
            return value
        }
        guard !decoded.isEmpty else {
            throw BarkVisorError.badRequest("Missing member API path")
        }
        return "/" + decoded.joined(separator: "/")
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

    private static func rejectPathSegment(_ part: String) throws {
        if part.isEmpty || part == "." || part == ".." || part.contains("/")
            || part.contains("\\") {
            throw BarkVisorError.badRequest("Invalid member API path")
        }
    }

    /// Image bytes stay on the agent plane. The Home proxy buffers and caps
    /// bodies at 10 MiB — a cloud image must not ride that path.
    public static func rejectLibraryBytes(_ path: String) throws {
        if LibraryDepotHTTP.isImageBytesPath(path) {
            throw BarkVisorError.badRequest(
                "Library image bytes are served on the agent plane, not the Home proxy",
            )
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

    /// VNC / serial console on a Device. Home tunnels these as WebSocket;
    /// the HTTP proxy must not wrap them (it strips `Upgrade`).
    public static func consoleKind(components: [String]) -> HomeConsoleKind? {
        guard components.count == 3, components[0] == "vms" else { return nil }
        switch components[2] {
        case "vnc": return .vnc
        case "console": return .console
        default: return nil
        }
    }

    public static func consoleKind(apiPath: String) throws -> HomeConsoleKind? {
        let normalized = try normalizedAPIPath(apiPath)
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4, parts[0] == "api" else { return nil }
        return consoleKind(components: Array(parts.dropFirst()))
    }

    public static func webSocketURL(from url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BarkVisorError.badRequest("Unable to build Device URL")
        }
        switch parts.scheme {
        case "https":
            parts.scheme = "wss"
        case "http":
            parts.scheme = "ws"
        case "wss", "ws":
            break
        default:
            throw BarkVisorError.badRequest("Unable to build Device URL")
        }
        guard let converted = parts.url else {
            throw BarkVisorError.badRequest("Unable to build Device URL")
        }
        return converted
    }

    /// Member mTLS (or This Device loopback) URL for VNC / serial console.
    /// Only the Device ticket is forwarded; Home `session=` stays on Home.
    public static func consoleTargetURL(_ target: HomeConsoleTarget) throws -> URL {
        let path = try memberAPIPath(components: ["vms", target.vmID, target.kind.rawValue])
        let query = forwardedConsoleQuery(target.query)
        let http: URL
        if target.isSelf {
            http = try localURL(port: target.localPort, path: path, query: query)
        } else {
            guard let agentHost = target.agentHost, !agentHost.isEmpty else {
                throw BarkVisorError.badRequest("Device has no reachable address")
            }
            http = try memberURL(
                host: agentHost,
                port: target.agentPort,
                path: path,
                query: query,
            )
        }
        return try webSocketURL(from: http)
    }

    /// Keep the Device ticket (`ticket=` or noVNC's `token=` rewrite). Drop
    /// Home `session=` so it is never sent to the member.
    public static func forwardedConsoleQuery(_ query: String?) -> String? {
        StreamTicketPolicy.hopQuery(from: query)
    }
}

/// Display or serial console for a Workload. Raw value is the API path tail.
public enum HomeConsoleKind: String, Sendable {
    case vnc
    case console
}

/// Where Home (or the agent hop) should open the console WebSocket.
public struct HomeConsoleTarget: Sendable {
    public var isSelf: Bool
    public var localPort: Int
    public var agentHost: String?
    public var agentPort: Int
    public var vmID: String
    public var kind: HomeConsoleKind
    public var query: String?

    public init(
        isSelf: Bool,
        localPort: Int,
        agentHost: String?,
        agentPort: Int,
        vmID: String,
        kind: HomeConsoleKind,
        query: String?,
    ) {
        self.isSelf = isSelf
        self.localPort = localPort
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.vmID = vmID
        self.kind = kind
        self.query = query
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
    func stream(_ request: HomeDeviceProxyRequest) -> AsyncThrowingStream<Data, Error>
}

extension HomeDeviceProxyClient {
    /// Default: buffer `send`, then yield one chunk. Used by test doubles.
    /// Non-2xx becomes `BarkVisorError.badGateway` so SSE proxies fail closed
    /// before writing HTTP 200.
    public func stream(_ request: HomeDeviceProxyRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(request)
                    if !(200 ..< 300).contains(response.status) {
                        let reason = String(data: response.body, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.finish(
                            throwing: BarkVisorError.badGateway(
                                reason.isEmpty ? "HTTP \(response.status)" : reason,
                            ),
                        )
                        return
                    }
                    if !response.body.isEmpty {
                        continuation.yield(response.body)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
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
