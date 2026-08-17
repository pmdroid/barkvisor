import Foundation

enum APIError: LocalizedError, Equatable {
    case invalidURL
    case unauthorized
    case setupRequired
    case http(status: Int, reason: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Device URL"
        case .unauthorized: "Sign in required"
        case .setupRequired: "Finish setup in the web UI"
        case let .http(_, reason): reason
        case let .decoding(message): message
        case let .transport(message): message
        }
    }
}

struct APIClient: Sendable {
    var baseURL: URL
    var token: String?

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    /// Device-scoped Device APIs (VMs, metrics, start/stop).
    /// `self` stays on `/api/...`. Members go through `/api/home/devices/{id}/v1/...`.
    func scoped(_ path: String, on device: HomeDeviceHealthSnapshot?) -> String {
        let trimmed = path.hasPrefix("/") ? path : "/\(path)"
        guard let device, !device.isSelf else { return "/api\(trimmed)" }
        return "/api/home/devices/\(device.hostId)/v1\(trimmed)"
    }

    func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: T.Type = T.self
    ) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: nil as EmptyJSON?, as: type)
    }

    func post<Body: Encodable, T: Decodable>(
        _ path: String,
        body: Body,
        as type: T.Type = T.self
    ) async throws -> T {
        try await send(method: "POST", path: path, body: body, as: type)
    }

    func post<Body: Encodable>(_ path: String, body: Body) async throws {
        let _: DiscardBody = try await send(method: "POST", path: path, body: body, as: DiscardBody.self)
    }

    func delete(_ path: String) async throws {
        let _: DiscardBody = try await send(method: "DELETE", path: path, body: nil as EmptyJSON?, as: DiscardBody.self)
    }

    func send<Body: Encodable, T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Body?,
        as _: T.Type
    ) async throws -> T {
        var request = try makeRequest(method: method, path: path, query: query)
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(request)
        if T.self == DiscardBody.self {
            return DiscardBody() as! T
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func probeSetup() async throws -> SetupStatus {
        try await get("/api/setup/status")
    }

    func localOnlyDevice() async -> HomeDeviceHealthSnapshot {
        let about = try? await about()
        return HomeDeviceHealthSnapshot(
            hostId: "self",
            role: "self",
            displayName: about.map { "This Device · \($0.platform)" } ?? "This Device",
            fingerprint: nil,
            agentHost: baseURL.host,
            agentPort: baseURL.port ?? DeviceURL.defaultPort,
            pairedAt: nil,
            reachability: "ok",
            reachabilityError: nil,
            collectedAt: nil,
            platform: about.map { HomeDevicePlatformSummary(os: $0.platform, arch: $0.hostArch) },
            resources: nil,
            workloadCount: nil,
            healthCounts: nil
        )
    }

    func login(username: String, password: String) async throws -> String {
        let response: LoginResponse = try await post(
            "/api/auth/login",
            body: LoginRequest(username: username, password: password)
        )
        return response.token
    }

    func healthReport() async throws -> HomeDeviceHealthReport {
        try await get("/api/home/devices/health")
    }

    func deviceList() async throws -> HomeDeviceList {
        try await get("/api/home/devices")
    }

    func workloads(on device: HomeDeviceHealthSnapshot?) async throws -> [Workload] {
        try await get(scoped("/vms", on: device))
    }

    func startWorkload(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(scoped("/vms/\(id)/start", on: device), body: EmptyJSON())
    }

    func stopWorkload(_ id: String, force: Bool, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(
            scoped("/vms/\(id)/stop", on: device),
            body: WorkloadStopBody(force: force, method: force ? "force" : "acpi")
        )
    }

    func stats(on device: HomeDeviceHealthSnapshot?) async throws -> SystemStats {
        try await get(scoped("/system/stats", on: device))
    }

    func about() async throws -> SystemAbout {
        try await get("/api/system/about")
    }

    func images(on device: HomeDeviceHealthSnapshot?) async throws -> [LibraryImage] {
        try await get(scoped("/images", on: device))
    }

    func disks(on device: HomeDeviceHealthSnapshot?) async throws -> [DiskRecord] {
        try await get(scoped("/disks", on: device))
    }

    func networks(on device: HomeDeviceHealthSnapshot?) async throws -> [NetworkRecord] {
        try await get(scoped("/networks", on: device))
    }

    func logs(limit: Int = 200) async throws -> [ServerLogEntry] {
        try await get("/api/logs", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func pairingCode() async throws -> PairingIssue? {
        do {
            return try await get("/api/pairing/codes")
        } catch let APIError.http(status, _) where status == 404 {
            return nil
        }
    }

    func issuePairingCode() async throws -> PairingIssue {
        try await post("/api/pairing/codes", body: EmptyJSON())
    }

    func revokePairingCode() async throws {
        try await delete("/api/pairing/codes")
    }

    private func makeRequest(method: String, path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Invalid response")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode == 503, reason(from: data) == "setup_required" {
            throw APIError.setupRequired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, reason: reason(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return (data, http)
    }

    private func reason(from data: Data) -> String? {
        (try? Self.decoder.decode(APIErrorBody.self, from: data))?.reason
    }
}

/// Used when the caller ignores the response body (204 / empty JSON).
struct DiscardBody: Decodable {
    init() {}
    init(from _: Decoder) throws { self.init() }
}

enum DeviceURL {
    static let defaultPort = 7777

    static var `default`: String {
        "http://192.168.30.1:7777"
    }

    /// One-time upgrade for host-only values saved before `normalize` required a scheme.
    static func migrateStored(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("://") else { return raw }
        return "http://\(value)"
    }

    /// Canonical Device origin: scheme + host + port. Paths are stripped so
    /// `makeRequest` never prefixes `/api/...` with a stored SPA or paste path.
    static func normalize(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") { value.removeLast() }
        guard value.contains("://") else { throw APIError.invalidURL }
        guard var components = URLComponents(string: value) else { throw APIError.invalidURL }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.invalidURL
        }
        components.scheme = scheme
        if components.port == nil, components.host != nil {
            components.port = defaultPort
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url, url.host != nil else { throw APIError.invalidURL }
        return url
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort) == (rhs.port ?? defaultPort)
    }
}

/// Classifies Home Device directory fallbacks. A 404 on health/list is only
/// "pre-Home" when `/api/system/about` proves this origin is a Device.
enum HomeDeviceDirectory {
    enum Resolution: Equatable {
        case health
        case registry
        case preHome
    }

    static func resolution(
        healthStatus: Int?,
        listStatus: Int?,
        aboutSucceeded: Bool
    ) throws -> Resolution {
        if healthStatus == nil { return .health }
        guard healthStatus == 404 else {
            throw APIError.http(status: healthStatus ?? 0, reason: "Device health request failed")
        }
        if listStatus == nil { return .registry }
        guard listStatus == 404 else {
            throw APIError.http(status: listStatus ?? 0, reason: "Device list request failed")
        }
        guard aboutSucceeded else {
            throw APIError.http(status: 404, reason: "Home Device list is unavailable")
        }
        return .preHome
    }

    static func httpStatus(from error: Error) -> Int? {
        guard let api = error as? APIError, case let .http(status, _) = api else { return nil }
        return status
    }
}
