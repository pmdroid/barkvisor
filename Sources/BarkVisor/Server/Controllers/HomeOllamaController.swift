import BarkVisorCore
import Foundation
import GRDB
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
        self.now = now
    }

    func boot(routes: any RoutesBuilder) throws {
        let home = routes.grouped("api", "home", "ollama")
        home.get("status", use: status)
        home.get("models", use: models)
        home.post("pull", use: pull)
        home.post("start", use: start)
        home.post("stop", use: stop)

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
        _ = try req.requireUser
        return try await refresh(db: req.db, bearer: req.headers.bearerAuthorization?.token)
    }

    @Sendable
    func models(req: Vapor.Request) async throws -> OllamaHomeCatalog {
        try await status(req: req)
    }

    @Sendable
    func pull(req: Vapor.Request) async throws -> OllamaTaskAccepted {
        _ = try req.requireUser
        let body = try req.content.decode(OllamaPullRequest.self)
        let target = try await targetHost(
            requested: body.hostId,
            model: nil,
            requirePulled: false,
            db: req.db,
            bearer: req.headers.bearerAuthorization?.token,
        )
        if target == hostId {
            return try await localOllama.pull(req: req)
        }
        return try await proxyJSON(
            hostId: target,
            method: "POST",
            path: "/api/ollama/pull",
            body: JSONEncoder().encode(["name": body.name]),
            bearer: req.headers.bearerAuthorization?.token,
            as: OllamaTaskAccepted.self,
        )
    }

    @Sendable
    func start(req: Vapor.Request) async throws -> HTTPStatus {
        _ = try req.requireUser
        let body = try req.content.decode(OllamaModelActionRequest.self)
        let target = try await targetHost(
            requested: body.hostId,
            model: body.name,
            requirePulled: true,
            db: req.db,
            bearer: req.headers.bearerAuthorization?.token,
        )
        if target == hostId {
            return try await localOllama.start(req: req)
        }
        try await proxyEmpty(
            hostId: target,
            method: "POST",
            path: "/api/ollama/start",
            body: JSONEncoder().encode(["name": body.name]),
            bearer: req.headers.bearerAuthorization?.token,
        )
        _ = try await refresh(db: req.db, bearer: req.headers.bearerAuthorization?.token)
        return .noContent
    }

    @Sendable
    func stop(req: Vapor.Request) async throws -> HTTPStatus {
        _ = try req.requireUser
        let body = try req.content.decode(OllamaModelActionRequest.self)
        let target = try await targetHost(
            requested: body.hostId,
            model: body.name,
            requirePulled: true,
            db: req.db,
            bearer: req.headers.bearerAuthorization?.token,
        )
        if target == hostId {
            return try await localOllama.stop(req: req)
        }
        try await proxyEmpty(
            hostId: target,
            method: "POST",
            path: "/api/ollama/stop",
            body: JSONEncoder().encode(["name": body.name]),
            bearer: req.headers.bearerAuthorization?.token,
        )
        _ = try await refresh(db: req.db, bearer: req.headers.bearerAuthorization?.token)
        return .noContent
    }

    @Sendable
    func nativeTags(req: Vapor.Request) async throws -> OllamaNativeTags {
        let catalog = try await status(req: req)
        return OllamaCatalog.nativeTags(
            from: catalog.models.map {
                OllamaLocalModel(name: $0.name, digest: $0.digest, size: $0.size, running: $0.running)
            },
        )
    }

    @Sendable
    func nativePS(req: Vapor.Request) async throws -> OllamaNativePS {
        let catalog = try await status(req: req)
        return OllamaCatalog.nativePS(
            from: catalog.models.map {
                OllamaLocalModel(name: $0.name, digest: $0.digest, size: $0.size, running: $0.running)
            },
        )
    }

    @Sendable
    func nativePull(req: Vapor.Request) async throws -> OllamaTaskAccepted {
        try await pull(req: req)
    }

    @Sendable
    func completions(req: Vapor.Request) async throws -> Response {
        _ = try req.requireUser
        let collected = try await req.body.collect(max: HomeDeviceProxy.maxBodyBytes).get()
        guard let buffer = collected else {
            throw BarkVisorError.badRequest("Missing chat completion body")
        }
        let data = Data(buffer.readableBytesView)
        let model = try OllamaLocalProbe.modelName(fromChatBody: data)
        let catalog = try await refresh(db: req.db, bearer: req.headers.bearerAuthorization?.token)
        guard let picked = OllamaRouter.pick(model: model, catalog: catalog, now: now?() ?? Date())
        else {
            throw BarkVisorError.notFound("No Device has Ollama model \(model)")
        }
        if picked.hostId == hostId {
            return try await localOllama.complete(body: data, db: req.db)
        }
        let result = try await sendMember(
            hostId: picked.hostId,
            method: "POST",
            path: "/api/ollama/v1/chat/completions",
            body: data,
            bearer: req.headers.bearerAuthorization?.token,
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(
            status: HTTPResponseStatus(statusCode: result.status),
            headers: headers,
            body: .init(data: result.body),
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

    func refresh(db: DatabasePool, bearer: String?) async throws -> OllamaHomeCatalog {
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
        if let bearer, !bearer.isEmpty {
            await withTaskGroup(of: OllamaDeviceSnapshot?.self) { group in
                for device in listed.devices where device.hostId != hostId {
                    group.addTask {
                        await self.probeMember(device, bearer: bearer)
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

    private func targetHost(
        requested: String?,
        model: String?,
        requirePulled: Bool,
        db: DatabasePool,
        bearer: String?,
    ) async throws -> String {
        if let requested, !requested.isEmpty {
            return requested
        }
        let catalog = try await refresh(db: db, bearer: bearer)
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

    private func probeMember(_ device: HomeDevice, bearer: String?) async -> OllamaDeviceSnapshot? {
        do {
            let result = try await sendMember(
                hostId: device.hostId,
                method: "GET",
                path: "/api/ollama/snapshot",
                body: nil,
                bearer: bearer,
            )
            guard (200 ..< 300).contains(result.status) else {
                return OllamaDeviceSnapshot(
                    hostId: device.hostId,
                    displayName: device.displayName,
                    installed: false,
                    reachable: false,
                    installHint: OllamaDetect.installHint(),
                    probedAt: iso8601.string(from: now?() ?? Date()),
                )
            }
            var snap = try JSONDecoder().decode(OllamaDeviceSnapshot.self, from: result.body)
            snap.hostId = device.hostId
            if snap.displayName == nil { snap.displayName = device.displayName }
            return snap
        } catch {
            return OllamaDeviceSnapshot(
                hostId: device.hostId,
                displayName: device.displayName,
                installed: false,
                reachable: false,
                installHint: OllamaDetect.installHint(),
                probedAt: iso8601.string(from: now?() ?? Date()),
            )
        }
    }

    private func proxyJSON<T: Decodable>(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        bearer: String?,
        as: T.Type,
    ) async throws -> T {
        let result = try await sendMember(
            hostId: hostId, method: method, path: path, body: body, bearer: bearer,
        )
        guard (200 ..< 300).contains(result.status) else {
            throw BarkVisorError.badGateway("Device Ollama request failed (\(result.status))")
        }
        return try JSONDecoder().decode(T.self, from: result.body)
    }

    private func proxyEmpty(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        bearer: String?,
    ) async throws {
        let result = try await sendMember(
            hostId: hostId, method: method, path: path, body: body, bearer: bearer,
        )
        guard (200 ..< 300).contains(result.status) else {
            throw BarkVisorError.badGateway("Device Ollama request failed (\(result.status))")
        }
    }

    private func sendMember(
        hostId: String,
        method: String,
        path: String,
        body: Data?,
        bearer: String?,
    ) async throws -> HomeDeviceProxyResponse {
        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        guard let record = try store.record(forHostId: hostId) else {
            throw BarkVisorError.notFound("Device not found")
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            throw BarkVisorError.badGateway("Device has no reachable address")
        }
        let url = try HomeDeviceProxy.memberURL(host: agentHost, port: record.agentPort, path: path)
        let client: any HomeDeviceProxyClient = if let mtlsClient {
            mtlsClient
        } else {
            try HomeDevicesMTLS.client(dataDir: dataDir, hostId: self.hostId)
        }
        var headers: [(String, String)] = [(APIContract.versionHeaderName, String(APIContract.version))]
        if let bearer {
            headers.append(("Authorization", "Bearer \(bearer)"))
        }
        if body != nil {
            headers.append(("Content-Type", "application/json"))
        }
        return try await client.send(
            HomeDeviceProxyRequest(method: method, url: url, headers: headers, body: body),
        )
    }
}
