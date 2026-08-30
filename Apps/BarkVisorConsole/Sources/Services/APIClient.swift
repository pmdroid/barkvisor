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

struct APIClient {
    static let chatCompletionsPath = "/v1/chat/completions"

    var baseURL: URL
    var token: String?
    /// Called once on 401. Only `.unauthorized` may drop the session; `.unavailable` must not.
    var refreshOnce: (() async -> SessionRefreshResult)?

    private static let decoder: JSONDecoder = .init()

    private static let encoder: JSONEncoder = .init()

    /// Path-segment encoding: `/` is reserved (host IDs like `peer/1` must stay one segment).
    private static let pathSegmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// Device-scoped Device APIs (VMs, metrics, start/stop/restart).
    /// `self` stays on `/api/...`. Members go through `/api/home/devices/{id}/v1/...`.
    func scoped(_ path: String, on device: HomeDeviceHealthSnapshot?) -> String {
        let trimmed = path.hasPrefix("/") ? path : "/\(path)"
        guard let device, !device.isSelf else { return "/api\(trimmed)" }
        let hostId = device.hostId.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? device.hostId
        return "/api/home/devices/\(hostId)/v1\(trimmed)"
    }

    func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: T.Type = T.self,
    ) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: nil as EmptyJSON?, as: type)
    }

    func post<T: Decodable>(
        _ path: String,
        body: some Encodable,
        as type: T.Type = T.self,
    ) async throws -> T {
        try await send(method: "POST", path: path, body: body, as: type)
    }

    func post(_ path: String, body: some Encodable) async throws {
        let _: DiscardBody = try await send(method: "POST", path: path, body: body, as: DiscardBody.self)
    }

    func delete(_ path: String) async throws {
        let _: DiscardBody = try await send(method: "DELETE", path: path, body: nil as EmptyJSON?, as: DiscardBody.self)
    }

    func send<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)?,
        as _: T.Type,
    ) async throws -> T {
        var request = try makeRequest(method: method, path: path, query: query)
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(request, allowRefresh: !isAuthBootstrap(path))
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
            displayName: {
                let name = about?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { return name }
                return about.map(\.platform) ?? "Device"
            }(),
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
            healthCounts: nil,
        )
    }

    func login(username: String, password: String) async throws -> SessionTokens {
        let response: LoginResponse = try await post(
            "/api/auth/login",
            body: LoginRequest(username: username, password: password),
        )
        return SessionTokens(token: response.token, refreshToken: response.refreshToken)
    }

    func beginPasskeyLogin() async throws -> PasskeyCeremonyBegin {
        try await postPasskey("/api/auth/passkeys/login/begin", body: EmptyJSON())
    }

    func finishPasskeyLogin(sessionId: String, credential: [String: Any]) async throws -> SessionTokens {
        let response: LoginResponse = try await postPasskey(
            "/api/auth/passkeys/login/finish",
            body: PasskeyLoginFinishBody(sessionId: sessionId, credential: JSONEncodable(value: credential)),
        )
        return SessionTokens(token: response.token, refreshToken: response.refreshToken)
    }

    func templates(on device: HomeDeviceHealthSnapshot?) async throws -> [VMTemplateRecord] {
        try await get(scoped("/templates", on: device))
    }

    func sshKeys() async throws -> [SSHKeyRecord] {
        try await get("/api/ssh-keys")
    }

    func deployTemplate(_ body: DeployTemplateBody, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        var request = try makeRequest(method: "POST", path: scoped("/templates/deploy", on: device), query: [])
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (data, response) = try await perform(request, allowRefresh: true)
        if response.statusCode == 202 {
            let accepted = try Self.decoder.decode(DeployTemplateResponse.self, from: data)
            guard let vm = accepted.vm else { throw APIError.decoding("Missing Workload in deploy response") }
            return vm
        }
        let deployed = try Self.decoder.decode(DeployTemplateResponse.self, from: data)
        guard let vm = deployed.vm else { throw APIError.decoding("Missing Workload in deploy response") }
        return vm
    }

    func refreshSession(refreshToken: String) async throws -> SessionTokens {
        let response: LoginResponse = try await post(
            "/api/auth/refresh",
            body: RefreshRequest(refreshToken: refreshToken),
        )
        return SessionTokens(token: response.token, refreshToken: response.refreshToken)
    }

    func redeemLogin(code: String) async throws -> SessionTokens {
        let response: LoginResponse = try await post(
            "/api/auth/login-offers/redeem",
            body: LoginRedeemRequest(code: code),
        )
        return SessionTokens(token: response.token, refreshToken: response.refreshToken)
    }

    func loginOffer() async throws -> LoginOfferIssue? {
        do {
            return try await get("/api/auth/login-offers")
        } catch let APIError.http(status, _) where status == 404 {
            return nil
        }
    }

    func issueLoginOffer(advertisedHost: String? = nil) async throws -> LoginOfferIssue {
        try await post(
            "/api/auth/login-offers",
            body: LoginOfferIssueRequest(advertisedHost: advertisedHost),
        )
    }

    func revokeLoginOffer() async throws {
        try await delete("/api/auth/login-offers")
    }

    func logout(refreshToken: String?) async throws {
        try await post("/api/auth/logout", body: LogoutRequest(refreshToken: refreshToken))
    }

    /// Single-use ticket for WebSocket query params. The session JWT stays on this POST.
    /// Members mint on the owning Device (`/api/home/devices/{id}/v1/auth/ws-ticket`).
    func createWSTicket(vmID: String, on device: HomeDeviceHealthSnapshot? = nil) async throws -> String {
        let response: WSTicketResponse = try await post(
            scoped("/auth/ws-ticket", on: device),
            body: WSTicketRequest(vmID: vmID),
        )
        return response.ticket
    }

    /// Home-minted `session=` so the WKWebView tunnel can auth without an Authorization header.
    func createHomeSessionTicket(vmID: String) async throws -> String {
        try await createWSTicket(vmID: vmID, on: nil)
    }

    func mintStreamTickets(
        vmID: String,
        on device: HomeDeviceHealthSnapshot?,
    ) async throws -> (ticket: String, session: String?) {
        let ticket = try await createWSTicket(vmID: vmID, on: device)
        if StreamTickets.needsHomeSession(device) {
            return try await (ticket, createHomeSessionTicket(vmID: vmID))
        }
        return (ticket, nil)
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

    /// POST /api/vms (or Home proxy). 200 returns the VM; 202 returns `{ taskID, vm }`.
    func createWorkload(_ body: CreateWorkload.Body, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        var request = try makeRequest(method: "POST", path: scoped("/vms", on: device), query: [])
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (data, response) = try await perform(request, allowRefresh: true)
        do {
            if response.statusCode == 202 {
                return try Self.decoder.decode(CreateWorkloadAccepted.self, from: data).vm
            }
            return try Self.decoder.decode(Workload.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func startWorkload(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(scoped("/vms/\(id)/start", on: device), body: EmptyJSON())
    }

    func stopWorkload(_ id: String, force: Bool, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(
            scoped("/vms/\(id)/stop", on: device),
            body: WorkloadStopBody(force: force, method: force ? "force" : "acpi"),
        )
    }

    func restartWorkload(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(scoped("/vms/\(id)/restart", on: device), body: EmptyJSON())
    }

    func setStartOnBoot(_ id: String, enabled: Bool, on device: HomeDeviceHealthSnapshot?) async throws {
        let _: Workload = try await send(
            method: "PATCH",
            path: scoped("/vms/\(id)", on: device),
            body: WorkloadStartOnBootBody(startOnBoot: enabled),
            as: Workload.self,
        )
    }

    func resumeSession(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        try await post(scoped("/vms/\(id)/session/resume", on: device), body: EmptyJSON())
    }

    func resetSession(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        try await post(scoped("/vms/\(id)/session/reset", on: device), body: EmptyJSON())
    }

    func burnSession(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(scoped("/vms/\(id)/session/burn", on: device), body: EmptyJSON())
    }

    func guestInfo(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws -> GuestInfo {
        try await get(scoped("/vms/\(id)/guest-info", on: device))
    }

    func attachISO(_ id: String, isoID: String, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(scoped("/vms/\(id)/attach-iso", on: device), body: ISOMediaBody(isoId: isoID))
    }

    func ejectISO(_ id: String, isoID: String, on device: HomeDeviceHealthSnapshot?) async throws {
        try await post(scoped("/vms/\(id)/detach-iso", on: device), body: ISOMediaBody(isoId: isoID))
    }

    func stats(on device: HomeDeviceHealthSnapshot?) async throws -> SystemStats {
        try await get(scoped("/system/stats", on: device))
    }

    func statsHistory(
        minutes: Int = DeviceStatsHistory.minutes,
        on device: HomeDeviceHealthSnapshot?,
    ) async throws -> [SystemStatsSample] {
        try await get(
            scoped("/system/stats/history", on: device),
            query: [URLQueryItem(name: "minutes", value: String(minutes))],
        )
    }

    func about(on device: HomeDeviceHealthSnapshot? = nil) async throws -> SystemAbout {
        try await get(scoped("/system/about", on: device))
    }

    func deviceName(on device: HomeDeviceHealthSnapshot) async throws -> DeviceNameSnapshot {
        try await get(scoped("/system/device-name", on: device))
    }

    func saveDeviceName(_ displayName: String, on device: HomeDeviceHealthSnapshot) async throws -> DeviceNameSnapshot {
        try await send(
            method: "PUT",
            path: scoped("/system/device-name", on: device),
            body: DeviceNameUpdate(displayName: displayName),
            as: DeviceNameSnapshot.self,
        )
    }

    func capabilities(on device: HomeDeviceHealthSnapshot? = nil) async throws -> SystemCapabilities {
        try await get(scoped("/system/capabilities", on: device))
    }

    func gpuDevices(on device: HomeDeviceHealthSnapshot?) async throws -> [HostGPUDevice] {
        try await get(scoped("/system/gpu-devices", on: device))
    }

    func usbDevices(on device: HomeDeviceHealthSnapshot?) async throws -> [HostUSBDevice] {
        try await get(scoped("/system/usb-devices", on: device))
    }

    func attachUSB(_ id: String, deviceId: String, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        try await post(scoped("/vms/\(id)/usb", on: device), body: GPUAttachBody(deviceId: deviceId))
    }

    func detachUSB(_ id: String, deviceId: String, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        try await send(
            method: "DELETE",
            path: scoped("/vms/\(id)/usb/\(deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId)", on: device),
            body: nil as EmptyJSON?,
            as: Workload.self,
        )
    }

    func attachGPU(_ id: String, pciAddress: String, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        try await post(scoped("/vms/\(id)/gpu", on: device), body: GPUAttachBody(deviceId: pciAddress))
    }

    func detachGPU(_ id: String, pciAddress: String, on device: HomeDeviceHealthSnapshot?) async throws -> Workload {
        try await send(
            method: "DELETE",
            path: scoped("/vms/\(id)/gpu/\(pciAddress.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pciAddress)", on: device),
            body: nil as EmptyJSON?,
            as: Workload.self,
        )
    }

    func images(on device: HomeDeviceHealthSnapshot?) async throws -> [LibraryImage] {
        try await get(scoped("/images", on: device))
    }

    func image(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws -> LibraryImage {
        try await get(scoped("/images/\(id)", on: device))
    }

    func repositories(on device: HomeDeviceHealthSnapshot?) async throws -> [ImageRepository] {
        try await get(scoped("/repositories", on: device))
    }

    func catalogImages(repositoryID: String, on device: HomeDeviceHealthSnapshot?) async throws -> [CatalogImage] {
        try await get(scoped("/repositories/\(repositoryID)/images", on: device))
    }

    func downloadCatalogImage(_ id: String, on device: HomeDeviceHealthSnapshot?) async throws -> LibraryImage {
        try await post(scoped("/repositories/images/\(id)/download", on: device), body: EmptyJSON())
    }

    func disks(on device: HomeDeviceHealthSnapshot?) async throws -> [DiskRecord] {
        try await get(scoped("/disks", on: device))
    }

    func networks(on device: HomeDeviceHealthSnapshot?) async throws -> [NetworkRecord] {
        try await get(scoped("/networks", on: device))
    }

    func browseFolders(path: String, on device: HomeDeviceHealthSnapshot?) async throws -> [FolderEntry] {
        let query = path.isEmpty ? [] : [URLQueryItem(name: "path", value: path)]
        return try await get(scoped("/system/browse", on: device), query: query)
    }

    func createBrowseFolder(
        parent: String,
        name: String,
        on device: HomeDeviceHealthSnapshot?,
    ) async throws -> FolderEntry {
        try await post(
            scoped("/system/browse/mkdir", on: device),
            body: BrowseCreateFolderBody(parent: parent, name: name),
        )
    }

    func applyHostBridge(
        interface: String?,
        action: String,
        confirm: Bool,
        addressing: String = "dhcp",
        address: String? = nil,
        gateway: String? = nil,
        dns: [String]? = nil,
        on device: HomeDeviceHealthSnapshot? = nil,
    ) async throws -> HostBridgeApplyResponse {
        try await post(
            scoped("/system/bridges", on: device),
            body: HostBridgeApplyBody(
                interface: interface,
                action: action,
                addressing: addressing,
                address: address,
                gateway: gateway,
                dns: dns,
                confirm: confirm,
            ),
        )
    }

    func logs(limit: Int = 200) async throws -> [ServerLogEntry] {
        try await get("/api/logs", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func ollamaCatalog() async throws -> OllamaHomeCatalog {
        try await get("/api/home/ollama/models")
    }

    func ollamaLibrarySearch(q: String) async throws -> OllamaLibrarySearchResponse {
        try await get(
            "/api/home/ollama/library/search",
            query: [URLQueryItem(name: "q", value: q)],
        )
    }

    func pullOllama(name: String, hostId: String?) async throws -> OllamaTaskAccepted {
        try await post("/api/home/ollama/pull", body: OllamaPullBody(name: name, hostId: hostId))
    }

    func startOllama(_ name: String, hostId: String?) async throws {
        try await post("/api/home/ollama/start", body: OllamaModelActionBody.start(name, hostId: hostId))
    }

    func stopOllama(_ name: String, hostId: String?) async throws {
        try await post("/api/home/ollama/stop", body: OllamaModelActionBody.stop(name, hostId: hostId))
    }

    func ollamaTask(_ task: OllamaTaskAccepted, selfHostId: String?) async throws -> OllamaTaskEvent {
        try await get(OllamaTaskPath.rest(taskID: task.taskID, hostId: task.hostId, selfHostId: selfHostId))
    }

    func cancelOllamaTask(_ task: OllamaTaskAccepted, selfHostId: String?) async throws {
        try await delete(OllamaTaskPath.rest(taskID: task.taskID, hostId: task.hostId, selfHostId: selfHostId))
    }

    func ollamaSettings() async throws -> OllamaSettingsSnapshot {
        try await get("/api/ollama/settings")
    }

    func saveOllamaSettings(_ body: OllamaSettingsUpdate) async throws -> OllamaSettingsSnapshot {
        try await send(method: "PUT", path: "/api/ollama/settings", body: body, as: OllamaSettingsSnapshot.self)
    }

    func diskSettings() async throws -> DiskSettingsSnapshot {
        try await get("/api/system/disk/settings")
    }

    func saveDiskSettings(_ body: DiskSettingsUpdate) async throws -> DiskSettingsSnapshot {
        try await send(method: "PUT", path: "/api/system/disk/settings", body: body, as: DiskSettingsSnapshot.self)
    }

    func checkUpdates() async throws -> UpdateCheckResponse {
        try await get("/api/system/updates/check")
    }

    func installUpdate(version: String) async throws -> UpdateTaskAccepted {
        try await post("/api/system/updates/install", body: UpdateInstallRequest(version: version))
    }

    func taskStatus(taskID: String) async throws -> BackgroundTaskSnapshot {
        try await get("/api/tasks/\(taskID)")
    }

    func processHealth() async throws -> ProcessHealthSnapshot {
        try await get("/api/health")
    }

    func streamChatCompletions(
        model: String,
        messages: [ChatWireMessage],
        onDelta: @escaping (String) async -> Void,
    ) async throws {
        var request = try makeRequest(method: "POST", path: Self.chatCompletionsPath, query: [])
        request.timeoutInterval = 3_600
        request.httpBody = try Self.encoder.encode(
            ChatCompletionBody(model: model, stream: true, messages: messages),
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try await streamChatBytes(request, allowRefresh: true, onDelta: onDelta)
    }

    func remoteAccess() async throws -> RemoteAccessStatus {
        try await get("/api/system/remote-access")
    }

    func saveRemoteAccess(_ body: RemoteAccessUpdate) async throws -> RemoteAccessStatus {
        try await send(
            method: "PUT",
            path: "/api/home/settings/remote-access",
            body: body,
            as: RemoteAccessStatus.self,
        )
    }

    func pairingCode() async throws -> PairingIssue? {
        do {
            return try await get("/api/pairing/codes")
        } catch let APIError.http(status, _) where status == 404 {
            return nil
        }
    }

    func issuePairingCode(advertisedHost: String? = nil) async throws -> PairingIssue {
        try await post("/api/pairing/codes", body: IssuePairingRequest(advertisedHost: advertisedHost))
    }

    func revokePairingCode() async throws {
        try await delete("/api/pairing/codes")
    }

    func listAPIKeys() async throws -> [APIKeyResponse] {
        try await get(APIKeyRoutes.collection)
    }

    func createAPIKey(name: String, expiresIn: String, kind: String) async throws -> APIKeyCreateResponse {
        try await post(
            APIKeyRoutes.collection,
            body: APIKeyCreateBody(name: name, expiresIn: expiresIn, kind: kind),
        )
    }

    func revokeAPIKey(id: String) async throws {
        try await delete(APIKeyRoutes.item(id))
    }

    /// Admin-only read. Inference callers get 403 from `JWTAuthMiddleware`.
    func auditLog(
        limit: Int,
        offset: Int,
        action: String? = nil,
        resourceType: String? = nil,
    ) async throws -> AuditLogResponse {
        try await get(
            AuditLogRoutes.collection,
            query: AuditLogQuery.items(limit: limit, offset: offset, action: action, resourceType: resourceType),
        )
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

    private func isAuthBootstrap(_ path: String) -> Bool {
        path == "/api/auth/login"
            || path == "/api/auth/refresh"
            || path == "/api/auth/logout"
            || path == "/api/auth/login-offers/redeem"
            || path == "/api/auth/passkeys/login/begin"
            || path == "/api/auth/passkeys/login/finish"
    }

    private func postPasskey<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type = T.self) async throws -> T {
        var request = try makeRequest(method: "POST", path: path, query: [])
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PasskeySupport.originHeader(for: baseURL), forHTTPHeaderField: "Origin")
        let (data, response) = try await perform(request, allowRefresh: false)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func perform(_ request: URLRequest, allowRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
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
        if let retry = try await retryAfter401(request, status: http.statusCode, allowRefresh: allowRefresh) {
            return try await perform(retry, allowRefresh: false)
        }
        if http.statusCode == 503, reason(from: data) == "setup_required" {
            throw APIError.setupRequired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.http(
                status: http.statusCode,
                reason: reason(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            )
        }
        return (data, http)
    }

    /// Chat streaming bypasses `perform`; still retry once on 401.
    func retryAfter401(
        _ request: URLRequest,
        status: Int,
        allowRefresh: Bool,
    ) async throws -> URLRequest? {
        guard status == 401 else { return nil }
        if allowRefresh, let refreshOnce {
            switch await Self.retryAfter401(refreshOnce()) {
            case let .retry(newToken):
                var retry = request
                retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                return retry
            case let .fail(error):
                throw error
            }
        }
        throw APIError.unauthorized
    }

    private func streamChatBytes(
        _ request: URLRequest,
        allowRefresh: Bool,
        onDelta: @escaping (String) async -> Void,
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Invalid response")
        }
        if let retry = try await retryAfter401(request, status: http.statusCode, allowRefresh: allowRefresh) {
            return try await streamChatBytes(retry, allowRefresh: false, onDelta: onDelta)
        }
        if http.statusCode == 503 { throw APIError.setupRequired }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.http(
                status: http.statusCode,
                reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            )
        }
        var buffer = ""
        for try await line in bytes.lines {
            buffer.append(line)
            buffer.append("\n")
            let deltas = ChatSSE.drain(buffer: &buffer)
            for delta in deltas {
                await onDelta(delta)
            }
        }
        if !buffer.isEmpty {
            buffer.append("\n")
            for delta in ChatSSE.drain(buffer: &buffer) {
                await onDelta(delta)
            }
        }
    }

    private func reason(from data: Data) -> String? {
        (try? Self.decoder.decode(APIErrorBody.self, from: data))?.reason
    }

    /// Map a refresh outcome after an API 401. Transport/5xx keep the Keychain refresh token.
    static func retryAfter401(_ refresh: SessionRefreshResult) -> AuthRefreshRetry {
        switch refresh {
        case let .rotated(token): .retry(token)
        case .unauthorized: .fail(.unauthorized)
        case let .unavailable(message): .fail(.transport(message))
        }
    }
}

enum AuthRefreshRetry: Equatable {
    case retry(String)
    case fail(APIError)
}

/// Used when the caller ignores the response body (204 / empty JSON).
struct DiscardBody: Decodable {
    init() {}
    init(from _: Decoder) throws {
        self.init()
    }
}

enum DeviceURL {
    static let defaultPort = 7_777

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
    /// Require an explicit `http`/`https` scheme so a JWT is never sent to an inferred origin.
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
        aboutSucceeded: Bool,
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
