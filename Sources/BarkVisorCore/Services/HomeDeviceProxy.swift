import AsyncHTTPClient
import Foundation
import NIOCore
import NIOSSL

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

/// `AsyncThrowingStream` whose producer `Task` cancels when the consumer
/// stops (disconnect / `break` / parent cancel).
public enum CancellableAsyncThrowingStream {
    public static func make<Element: Sendable>(
        _ work: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation) async -> Void,
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await work(continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum HomeDeviceProxyError: Error, LocalizedError, Sendable, Equatable {
    case unreachable(String)
    case connectTimeout
    case cancelled
    case tlsFailure
    case memberHTTP(Int)
    case healthUnreachable
    case responseTooLarge

    /// Token written to `HomeDeviceHealthSnapshot.reachability`.
    public var reachability: String {
        switch self {
        case .unreachable, .healthUnreachable:
            HomeDeviceHealthAggregator.unreachable
        case .connectTimeout:
            HomeDeviceHealthAggregator.connectTimeout
        case .cancelled:
            HomeDeviceHealthAggregator.cancelled
        case .tlsFailure:
            HomeDeviceHealthAggregator.tlsFailure
        case .memberHTTP:
            HomeDeviceHealthAggregator.memberHTTP
        case .responseTooLarge:
            HomeDeviceHealthAggregator.responseTooLarge
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .unreachable(reason):
            "Device is unreachable: \(reason)"
        case .connectTimeout:
            "Home cannot hop to the Device: connection timed out"
        case .cancelled:
            "Home cannot hop to the Device: the hop was cancelled"
        case .tlsFailure:
            "Home cannot hop to the Device: TLS handshake failed"
        case let .memberHTTP(status):
            "Device returned HTTP \(status)"
        case .healthUnreachable:
            "Device is unreachable"
        case .responseTooLarge:
            "Device response is too large"
        }
    }

    /// Chat / Ollama hop copy. Member 5xx is Ollama down. 4xx means the Device
    /// answered and the request was rejected; Ollama itself may still be up.
    public var ollamaHopDescription: String {
        switch self {
        case let .memberHTTP(status) where (500 ..< 600).contains(status):
            "Ollama is down on the Device (HTTP \(status))"
        default:
            errorDescription ?? "Home cannot hop to the Device"
        }
    }

    /// Agent-plane loopback hop (`:7778` → This Device host API).
    public var localHopDescription: String {
        switch self {
        case .connectTimeout:
            "Local host API timed out"
        case .cancelled:
            "Local host API hop was cancelled"
        case .tlsFailure:
            "Local host API TLS handshake failed"
        case let .memberHTTP(status):
            "Local host API returned HTTP \(status)"
        case .healthUnreachable:
            "Local host API is unreachable"
        case let .unreachable(reason):
            "Local host API is unreachable: \(reason)"
        case .responseTooLarge:
            "Local host API response is too large"
        }
    }

    /// Map AsyncHTTPClient / NIO / cancellation into hop cases. Tests inject
    /// already-classified errors through ``HomeDeviceProxyClient``.
    public static func classify(_ error: Error) -> HomeDeviceProxyError {
        if let already = error as? HomeDeviceProxyError {
            return already
        }
        if error is CancellationError {
            return .cancelled
        }
        if let http = error as? HTTPClientError {
            return classifyHTTPClient(http)
        }
        if let channel = error as? ChannelError, case .connectTimeout = channel {
            return .connectTimeout
        }
        if error is NIOSSLError || error is BoringSSLError || error is NIOSSLCloseTimedOutError {
            return .tlsFailure
        }
        let blob = "\(error) \(error.localizedDescription)".lowercased()
        if blob.contains("tls") || blob.contains("ssl") || blob.contains("handshake") {
            return .tlsFailure
        }
        if blob.contains("cancel") {
            return .cancelled
        }
        if blob.contains("timeout") || blob.contains("timed out") {
            return .connectTimeout
        }
        if blob.contains("httpclienterror") {
            return .connectTimeout
        }
        return .unreachable(error.localizedDescription)
    }

    private static func classifyHTTPClient(_ http: HTTPClientError) -> HomeDeviceProxyError {
        if http == .cancelled || http == .requestStreamCancelled {
            return .cancelled
        }
        if http == .tlsHandshakeTimeout {
            return .tlsFailure
        }
        return .connectTimeout
    }
}
