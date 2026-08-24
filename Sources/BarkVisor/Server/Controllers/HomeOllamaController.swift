import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

/// Home Ollama catalog, routing, and native HTTP aliases (PAS-269).
struct HomeOllamaController: RouteCollection {
    var backgroundTasks: BackgroundTaskManager
    var dataDir: URL
    var hostId: String
    var localPort: Int
    var devices: DeviceRegistry?
    var mtlsClient: (any HomeDeviceProxyClient)?
    var localClient: any HomeDeviceProxyClient
    var store: OllamaCatalogStore
    var localOllama: OllamaController
    var keys: JWTKeyCollection?
    var now: (@Sendable () -> Date)?

    init(
        backgroundTasks: BackgroundTaskManager,
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
        localPort: Int = Config.port,
        devices: DeviceRegistry? = nil,
        mtlsClient: (any HomeDeviceProxyClient)? = nil,
        localClient: any HomeDeviceProxyClient = LocalHostProxyClient(),
        store: OllamaCatalogStore? = nil,
        localOllama: OllamaController,
        keys: JWTKeyCollection? = nil,
        now: (@Sendable () -> Date)? = nil,
    ) {
        self.backgroundTasks = backgroundTasks
        self.dataDir = dataDir
        self.hostId = hostId
        self.localPort = localPort
        self.devices = devices
        self.mtlsClient = mtlsClient
        self.localClient = localClient
        self.store = store ?? OllamaCatalogStore(dataDir: dataDir)
        self.localOllama = localOllama
        self.keys = keys
        self.now = now
    }

    func boot(routes: any RoutesBuilder) throws {
        let home = routes.grouped("api", "home", "ollama")
        home.get("status", use: status)
        home.get("models", use: models)
        home.post("pull", use: pull)
        home.post("start", use: start)
        home.post("stop", use: stop)
        home.get("settings", use: getSettings)
        home.put("settings", use: putSettings)

        routes.get("api", "ollama", "settings", use: getSettings)
        routes.put("api", "ollama", "settings", use: putSettings)

        routes.get("api", "tags", use: nativeTags)
        routes.get("api", "ps", use: nativePS)
        routes.post("api", "pull", use: nativePull)
        routes.post("api", "v1", "chat", "completions", use: completions)
        routes.get("api", "v1", "models", use: openAIModels)
        routes.post("v1", "chat", "completions", use: completions)
        routes.get("v1", "models", use: openAIModels)
    }

    @Sendable
    func status(req: Vapor.Request) async throws -> OllamaHomeCatalog {
        let user = try req.requireUser
        return try await refresh(db: req.db, user: user)
    }

    @Sendable
    func models(req: Vapor.Request) async throws -> OllamaHomeCatalog {
        try await status(req: req)
    }

    @Sendable
    func pull(req: Vapor.Request) async throws -> OllamaTaskAccepted {
        let user = try req.requireUser
        let body = try req.content.decode(OllamaPullRequest.self)
        let target = try await targetHost(
            requested: body.hostId,
            model: nil,
            requirePulled: false,
            db: req.db,
            user: user,
        )
        if target == hostId {
            return try await localOllama.pull(body: body, db: req.db)
        }
        return try await proxyJSON(
            hostId: target,
            method: "POST",
            path: "/api/ollama/pull",
            body: JSONEncoder().encode(["name": body.name]),
            user: user,
            as: OllamaTaskAccepted.self,
        )
    }

    @Sendable
    func start(req: Vapor.Request) async throws -> HTTPStatus {
        let user = try req.requireUser
        let body = try req.content.decode(OllamaModelActionRequest.self)
        let target = try await targetHost(
            requested: body.hostId,
            model: body.name,
            requirePulled: true,
            db: req.db,
            user: user,
        )
        if target == hostId {
            return try await localOllama.start(body: body, db: req.db)
        }
        try await proxyEmpty(
            hostId: target,
            method: "POST",
            path: "/api/ollama/start",
            body: JSONEncoder().encode(["name": body.name]),
            user: user,
        )
        _ = try await refresh(db: req.db, user: user)
        return .noContent
    }

    @Sendable
    func stop(req: Vapor.Request) async throws -> HTTPStatus {
        let user = try req.requireUser
        let body = try req.content.decode(OllamaModelActionRequest.self)
        let target = try await targetHost(
            requested: body.hostId,
            model: body.name,
            requirePulled: true,
            db: req.db,
            user: user,
        )
        if target == hostId {
            return try await localOllama.stop(body: body, db: req.db)
        }
        try await proxyEmpty(
            hostId: target,
            method: "POST",
            path: "/api/ollama/stop",
            body: JSONEncoder().encode(["name": body.name]),
            user: user,
        )
        _ = try await refresh(db: req.db, user: user)
        return .noContent
    }

    @Sendable
    func getSettings(req: Vapor.Request) async throws -> OllamaSettingsSnapshot {
        _ = try Self.requireAdmin(req)
        return try await listSettings(db: req.db)
    }

    @Sendable
    func putSettings(req: Vapor.Request) async throws -> OllamaSettingsSnapshot {
        let user = try Self.requireAdmin(req)
        let body = try req.content.decode(OllamaSettingsUpdate.self)
        return try await putSettings(body: body, db: req.db, user: user)
    }

    func putSettings(
        body: OllamaSettingsUpdate,
        db: DatabasePool,
        user: AuthenticatedUser,
    ) async throws -> OllamaSettingsSnapshot {
        let target = body.hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty, target != hostId, body.endpoint != nil || body.apiKey != nil {
            try await proxyEmpty(
                hostId: target,
                method: "PUT",
                path: "/api/ollama/settings",
                body: JSONEncoder().encode(
                    OllamaSettingsUpdate(
                        hostId: target,
                        endpoint: body.endpoint,
                        apiKey: body.apiKey,
                    ),
                ),
                user: user,
            )
        }
        return try await db.write { db in
            try OllamaSettings.save(
                hostId: body.hostId,
                endpoint: body.endpoint,
                apiKey: body.apiKey,
                updateApiKey: body.apiKey != nil,
                selfHostId: hostId,
                db: db,
            )
        }
    }

    func listSettings(db: DatabasePool) async throws -> OllamaSettingsSnapshot {
        let listed = HomeDeviceDirectory.list(
            dataDir: dataDir,
            hostId: hostId,
            displayName: ProcessInfo.processInfo.hostName,
            devices: devices,
        )
        return try await db.write { db in
            try OllamaSettings.list(
                knownHostIds: listed.devices.map(\.hostId),
                selfHostId: hostId,
                from: db,
            )
        }
    }

    static func requireAdmin(_ req: Vapor.Request) throws -> AuthenticatedUser {
        let user = try req.requireUser
        guard user.userRole == .admin else {
            throw BarkVisorError.forbidden("Admin only")
        }
        return user
    }

    @Sendable
    func nativeTags(req: Vapor.Request) async throws -> OllamaNativeTags {
        let catalog = try await status(req: req)
        let selfHostId = hostId
        return OllamaCatalog.nativeTags(
            from: catalog.models.map {
                OllamaLocalModel(
                    name: $0.name,
                    digest: $0.digest,
                    size: $0.size,
                    sizeVRAM: Self.runningSizeVRAM(selfHostId: selfHostId, locations: $0.locations),
                    running: $0.running,
                )
            },
        )
    }

    @Sendable
    func nativePS(req: Vapor.Request) async throws -> OllamaNativePS {
        let catalog = try await status(req: req)
        let selfHostId = hostId
        return OllamaCatalog.nativePS(
            from: catalog.models.map {
                OllamaLocalModel(
                    name: $0.name,
                    digest: $0.digest,
                    size: $0.size,
                    sizeVRAM: Self.runningSizeVRAM(selfHostId: selfHostId, locations: $0.locations),
                    running: $0.running,
                )
            },
        )
    }

    /// Prefer this Device when it is running the model; otherwise the running location with the lowest hostId.
    static func runningSizeVRAM(selfHostId: String, locations: [OllamaModelLocation]) -> Int64? {
        let running = locations.filter(\.running)
        if let own = running.first(where: { $0.hostId == selfHostId }) {
            return own.sizeVRAM
        }
        return running.min { $0.hostId < $1.hostId }?.sizeVRAM
    }

    @Sendable
    func nativePull(req: Vapor.Request) async throws -> OllamaTaskAccepted {
        try await pull(req: req)
    }

    @Sendable
    func completions(req: Vapor.Request) async throws -> Response {
        let user = try req.requireUser
        let collected = try await req.body.collect(max: HomeDeviceProxy.maxBodyBytes).get()
        guard let buffer = collected else {
            throw BarkVisorError.badRequest("Missing chat completion body")
        }
        let data = Data(buffer.readableBytesView)
        let model = try OllamaLocalProbe.modelName(fromChatBody: data)
        let catalog = try await catalogForCompletion(model: model, db: req.db, user: user)
        guard let picked = OllamaRouter.pick(model: model, catalog: catalog, now: now?() ?? Date())
        else {
            throw BarkVisorError.notFound("No Device has Ollama model \(model)")
        }
        let stream = OllamaLocalProbe.wantsStream(fromChatBody: data)
        if picked.hostId == hostId {
            return try await localOllama.complete(body: data, db: req.db)
        }
        if stream {
            let memberStream = try await sendMemberStream(
                hostId: picked.hostId,
                method: "POST",
                path: "/api/ollama/v1/chat/completions",
                body: data,
                user: user,
                timeoutSeconds: OllamaChatProxy.streamTimeoutSeconds,
            )
            return try await OllamaChatProxy.stream(memberStream)
        }
        let result = try await sendMember(
            hostId: picked.hostId,
            method: "POST",
            path: "/api/ollama/v1/chat/completions",
            body: data,
            user: user,
            timeoutSeconds: OllamaChatProxy.streamTimeoutSeconds,
        )
        return OllamaChatProxy.buffered(
            status: result.status,
            body: result.body,
            stream: false,
            memberHeaders: result.headers,
        )
    }

    @Sendable
    func openAIModels(req: Vapor.Request) async throws -> Response {
        let catalog = try await status(req: req)
        let payload: [String: Any] = [
            "object": "list",
            "data": catalog.models.map { ["id": $0.name, "object": "model", "owned_by": "ollama"] },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    func refresh(db: DatabasePool, user: AuthenticatedUser? = nil) async throws -> OllamaHomeCatalog {
        let listed = HomeDeviceDirectory.list(
            dataDir: dataDir,
            hostId: hostId,
            displayName: ProcessInfo.processInfo.hostName,
            devices: devices,
        )
        var snapshots: [OllamaDeviceSnapshot] = []
        let local = try await localOllama.currentSnapshot(db: db)
        snapshots.append(local)

        let previous = (try? store.load())?.devices ?? []
        if let user {
            let hopBearer = try await memberHopBearer(for: user)
            await withTaskGroup(of: OllamaDeviceSnapshot?.self) { group in
                for device in listed.devices where device.hostId != hostId {
                    group.addTask {
                        await self.probeMember(device, hopBearer: hopBearer)
                    }
                }
                for await snap in group {
                    if let snap { snapshots.append(snap) }
                }
            }
        } else {
            snapshots.append(contentsOf: previous.filter { $0.hostId != hostId })
        }

        let persisted = OllamaPersistedMap(
            refreshedAt: iso8601.string(from: now?() ?? Date()),
            devices: snapshots,
        )
        try store.save(persisted)
        return OllamaHomeMap.catalog(persisted: persisted, now: now?() ?? Date())
    }

    func catalogFromStore() throws -> OllamaHomeCatalog {
        let persisted = try store.load()
        return OllamaHomeMap.catalog(persisted: persisted, now: now?() ?? Date())
    }

    func catalogForCompletion(
        model: String,
        db: DatabasePool,
        user: AuthenticatedUser,
    ) async throws -> OllamaHomeCatalog {
        let now = now?() ?? Date()
        let stored = try? catalogFromStore()
        if !OllamaHomeMap.needsProbe(model: model, catalog: stored, now: now), let stored {
            return stored
        }
        return try await refresh(db: db, user: user)
    }

    private func targetHost(
        requested: String?,
        model: String?,
        requirePulled: Bool,
        db: DatabasePool,
        user: AuthenticatedUser?,
    ) async throws -> String {
        if let requested, !requested.isEmpty {
            return requested
        }
        let catalog = try await refresh(db: db, user: user)
        if let model, requirePulled {
            if let picked = OllamaRouter.pick(model: model, catalog: catalog, now: now?() ?? Date()) {
                return picked.hostId
            }
            throw BarkVisorError.notFound("No Device has Ollama model \(model)")
        }
        if let live = catalog.devices.first(where: { $0.reachable && !$0.stale }) {
            return live.hostId
        }
        throw BarkVisorError.badGateway("Ollama is not reachable on any Device")
    }

    func probeMember(_ device: HomeDevice, hopBearer: String) async -> OllamaDeviceSnapshot? {
        do {
            let result = try await sendMember(
                hostId: device.hostId,
                method: "GET",
                path: "/api/ollama/snapshot",
                body: nil,
                hopBearer: hopBearer,
            )
            guard (200 ..< 300).contains(result.status) else {
                return ollamaHopFailure(
                    device,
                    error: .memberHTTP(result.status),
                )
            }
            var snap = try JSONDecoder().decode(OllamaDeviceSnapshot.self, from: result.body)
            snap.hostId = device.hostId
            if snap.displayName == nil { snap.displayName = device.displayName }
            return snap
        } catch {
            return ollamaHopFailure(device, error: HomeDeviceProxyError.classify(error))
        }
    }

    private func ollamaHopFailure(
        _ device: HomeDevice,
        error: HomeDeviceProxyError,
    ) -> OllamaDeviceSnapshot {
        OllamaDeviceSnapshot(
            hostId: device.hostId,
            displayName: device.displayName,
            installed: false,
            reachable: false,
            installHint: error.ollamaHopDescription,
            probedAt: iso8601.string(from: now?() ?? Date()),
        )
    }

    private func proxyJSON<T: Decodable>(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        user: AuthenticatedUser,
        as: T.Type,
    ) async throws -> T {
        let result = try await sendMember(
            hostId: hostId, method: method, path: path, body: body, user: user,
        )
        guard (200 ..< 300).contains(result.status) else {
            throw BarkVisorError.badGateway(
                HomeDeviceProxyError.memberHTTP(result.status).ollamaHopDescription,
            )
        }
        return try JSONDecoder().decode(T.self, from: result.body)
    }

    private func proxyEmpty(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        user: AuthenticatedUser,
    ) async throws {
        let result = try await sendMember(
            hostId: hostId, method: method, path: path, body: body, user: user,
        )
        guard (200 ..< 300).contains(result.status) else {
            throw BarkVisorError.badGateway(
                HomeDeviceProxyError.memberHTTP(result.status).ollamaHopDescription,
            )
        }
    }

    func memberHopBearer(for user: AuthenticatedUser) async throws -> String {
        guard let keys else {
            throw BarkVisorError.internalError("Home JWT keys are not configured")
        }
        return try await AuthService.signMemberHopToken(
            userId: user.userId,
            username: user.username,
            role: AuthService.memberHopRole(
                userRole: user.role,
                authMethod: user.authMethod,
                apiKeyKind: user.apiKeyKind,
            ),
            keys: keys,
            now: now?() ?? Date(),
        )
    }

    func sendMember(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        user: AuthenticatedUser,
        timeoutSeconds: Int64? = nil,
    ) async throws -> HomeDeviceProxyResponse {
        let hopBearer = try await memberHopBearer(for: user)
        return try await sendMember(
            hostId: hostId,
            method: method,
            path: path,
            body: body,
            hopBearer: hopBearer,
            timeoutSeconds: timeoutSeconds,
        )
    }

    func sendMember(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        hopBearer: String,
        timeoutSeconds: Int64? = nil,
    ) async throws -> HomeDeviceProxyResponse {
        let prepared = try prepareMemberHop(
            hostId: hostId,
            method: method,
            path: path,
            body: body,
            hopBearer: hopBearer,
            timeoutSeconds: timeoutSeconds,
        )
        do {
            return try await prepared.client.send(prepared.request)
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.badGateway(
                HomeDeviceProxyError.classify(error).ollamaHopDescription,
            )
        }
    }

    func sendMemberStream(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        user: AuthenticatedUser,
        timeoutSeconds: Int64? = nil,
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let hopBearer = try await memberHopBearer(for: user)
        return try sendMemberStream(
            hostId: hostId,
            method: method,
            path: path,
            body: body,
            hopBearer: hopBearer,
            timeoutSeconds: timeoutSeconds,
        )
    }

    func sendMemberStream(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        hopBearer: String,
        timeoutSeconds: Int64? = nil,
    ) throws -> AsyncThrowingStream<Data, Error> {
        let prepared = try prepareMemberHop(
            hostId: hostId,
            method: method,
            path: path,
            body: body,
            hopBearer: hopBearer,
            timeoutSeconds: timeoutSeconds,
        )
        let inner = prepared.client.stream(prepared.request)
        return CancellableAsyncThrowingStream.make { continuation in
            do {
                for try await chunk in inner {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch let error as BarkVisorError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(
                    throwing: BarkVisorError.badGateway(
                        HomeDeviceProxyError.classify(error).ollamaHopDescription,
                    ),
                )
            }
        }
    }

    private func prepareMemberHop(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        hopBearer: String,
        timeoutSeconds: Int64?,
    ) throws -> (client: any HomeDeviceProxyClient, request: HomeDeviceProxyRequest) {
        if hopBearer.hasPrefix("barkvisor_") {
            throw BarkVisorError.internalError("API keys cannot authenticate on member Devices")
        }
        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        guard let record = try store.record(forHostId: hostId) else {
            throw BarkVisorError.notFound("Device not found")
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            throw BarkVisorError.badGateway("Device has no reachable address")
        }
        let url = try HomeDeviceProxy.memberURL(host: agentHost, port: record.agentPort, path: path)
        let client = try memberClient(timeoutSeconds: timeoutSeconds)
        var headers: [(String, String)] = [(APIContract.versionHeaderName, String(APIContract.version))]
        headers.append(("Authorization", "Bearer \(hopBearer)"))
        if body != nil {
            headers.append(("Content-Type", "application/json"))
        }
        return (
            client,
            HomeDeviceProxyRequest(method: method, url: url, headers: headers, body: body),
        )
    }

    private func memberClient(timeoutSeconds: Int64?) throws -> any HomeDeviceProxyClient {
        if let mtlsClient { return mtlsClient }
        guard let timeoutSeconds else {
            return try HomeDevicesMTLS.client(dataDir: dataDir, hostId: hostId)
        }
        let receipt = try? PairingService.loadReceipt(dataDir: dataDir)
        let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
        return AgentMTLSClient(
            material: material,
            presentationCertificatePEM: AgentPlaneCertificates.presentationCertificatePEM(
                material: material,
                receipt: receipt,
            ),
            trustCertificatePEMs: AgentPlaneCertificates.trustCertificatePEMs(
                material: material,
                receipt: receipt,
            ),
            timeoutSeconds: timeoutSeconds,
        )
    }
}
