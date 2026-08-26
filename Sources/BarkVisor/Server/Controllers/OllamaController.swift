import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct OllamaPullRequest: Content {
    var name: String
    var hostId: String?
}

struct OllamaModelActionRequest: Content {
    var name: String
    var hostId: String?
}

struct OllamaTaskAccepted: Content {
    var taskID: String
    var hostId: String
}

/// Device-local host Ollama HTTP (PAS-269).
struct OllamaController: RouteCollection {
    var backgroundTasks: BackgroundTaskManager
    var hostId: String
    var dataDir: URL
    var makeBackend: (@Sendable (DatabasePool) async throws -> any InferenceBackend)?
    var detect: (@Sendable () -> OllamaDetectResult)?
    var resources: (@Sendable () -> ResourcesInfo)?
    var displayName: String

    init(
        backgroundTasks: BackgroundTaskManager,
        hostId: String = Config.hostId,
        dataDir: URL = Config.dataDir,
        displayName: String = ProcessInfo.processInfo.hostName,
        makeBackend: (@Sendable (DatabasePool) async throws -> any InferenceBackend)? = nil,
        detect: (@Sendable () -> OllamaDetectResult)? = nil,
        resources: (@Sendable () -> ResourcesInfo)? = nil,
    ) {
        self.backgroundTasks = backgroundTasks
        self.hostId = hostId
        self.dataDir = dataDir
        self.displayName = displayName
        self.makeBackend = makeBackend
        self.detect = detect
        self.resources = resources
    }

    func boot(routes: any RoutesBuilder) throws {
        let ollama = routes.grouped("api", "ollama")
        ollama.get("status", use: status)
        ollama.get("snapshot", use: snapshot)
        ollama.get("tags", use: tags)
        ollama.get("ps", use: ps)
        ollama.post("pull", use: pull)
        ollama.post("start", use: start)
        ollama.post("stop", use: stop)
        ollama.post("v1", "chat", "completions", use: localCompletions)
    }

    @Sendable
    func status(req: Vapor.Request) async throws -> OllamaDeviceStatus {
        let snap = try await currentSnapshot(db: req.db)
        return OllamaDeviceStatus(
            hostId: snap.hostId,
            displayName: snap.displayName,
            installed: snap.installed,
            reachable: snap.reachable,
            stale: false,
            binaryPath: snap.binaryPath,
            installHint: snap.installHint,
            probedAt: snap.probedAt,
        )
    }

    @Sendable
    func snapshot(req: Vapor.Request) async throws -> OllamaDeviceSnapshot {
        try await currentSnapshot(db: req.db)
    }

    @Sendable
    func tags(req: Vapor.Request) async throws -> OllamaNativeTags {
        let snap = try await currentSnapshot(db: req.db)
        return OllamaCatalog.nativeTags(from: snap.models)
    }

    @Sendable
    func ps(req: Vapor.Request) async throws -> OllamaNativePS {
        let snap = try await currentSnapshot(db: req.db)
        return OllamaCatalog.nativePS(from: snap.models)
    }

    @Sendable
    func pull(req: Vapor.Request) async throws -> OllamaTaskAccepted {
        _ = try req.requireUser
        let body = try req.content.decode(OllamaPullRequest.self)
        return try await pull(body: body, db: req.db)
    }

    func pull(body: OllamaPullRequest, db: DatabasePool) async throws -> OllamaTaskAccepted {
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BarkVisorError.badRequest("Model name is required") }
        let backend = try await resolvedBackend(db: db)
        guard await backend.isReachable() else {
            throw BarkVisorError.badGateway("Ollama is not reachable on this Device")
        }
        let taskID = UUID().uuidString
        let tasks = backgroundTasks
        await tasks.submit(taskID, kind: .ollamaPull) {
            for try await event in backend.pull(name: name) {
                try Task.checkCancellation()
                if let fraction = event.fraction {
                    await tasks.reportProgress(taskID, progress: fraction)
                }
            }
            return name
        }
        return OllamaTaskAccepted(taskID: taskID, hostId: hostId)
    }

    @Sendable
    func start(req: Vapor.Request) async throws -> HTTPStatus {
        let body = try req.content.decode(OllamaModelActionRequest.self)
        return try await start(body: body, db: req.db)
    }

    func start(body: OllamaModelActionRequest, db: DatabasePool) async throws -> HTTPStatus {
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BarkVisorError.badRequest("Model name is required") }
        let snap = try await currentSnapshot(db: db)
        let backend = try await resolvedBackend(db: db)
        guard await backend.isReachable() else {
            throw BarkVisorError.badGateway("Ollama is not reachable on this Device")
        }
        let model = snap.models.first { OllamaModelName.matches(name, available: $0.name) }
        let fit = OllamaFit.check(
            modelBytes: model?.size,
            memoryTotalMB: snap.memoryTotalMB,
            memoryUsedMB: snap.memoryUsedMB,
        )
        guard fit.ok else {
            throw BarkVisorError.preconditionFailed(fit.reason ?? "Model does not fit in memory")
        }
        try await backend.start(model: model?.name ?? name)
        return .noContent
    }

    @Sendable
    func stop(req: Vapor.Request) async throws -> HTTPStatus {
        let body = try req.content.decode(OllamaModelActionRequest.self)
        return try await stop(body: body, db: req.db)
    }

    func stop(body: OllamaModelActionRequest, db: DatabasePool) async throws -> HTTPStatus {
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BarkVisorError.badRequest("Model name is required") }
        let backend = try await resolvedBackend(db: db)
        guard await backend.isReachable() else {
            throw BarkVisorError.badGateway("Ollama is not reachable on this Device")
        }
        try await backend.stop(model: name)
        return .noContent
    }

    @Sendable
    func localCompletions(req: Vapor.Request) async throws -> Response {
        let collected = try await req.body.collect(max: HomeDeviceProxy.maxBodyBytes).get()
        guard let buffer = collected else {
            throw BarkVisorError.badRequest("Missing chat completion body")
        }
        return try await complete(body: Data(buffer.readableBytesView), db: req.db)
    }

    func complete(body: Data, db: DatabasePool) async throws -> Response {
        _ = try OllamaLocalProbe.modelName(fromChatBody: body)
        let backend = try await resolvedBackend(db: db)
        if OllamaLocalProbe.wantsStream(fromChatBody: body) {
            return try await OllamaChatProxy.stream(backend.chatCompletionsStream(body: body))
        }
        let upstream = try await backend.chatCompletions(body: body)
        return OllamaChatHTTP.response(
            status: upstream.status,
            headers: upstream.headers,
            body: upstream.body,
        )
    }

    func currentSnapshot(db: DatabasePool) async throws -> OllamaDeviceSnapshot {
        let detectResult = detect?() ?? OllamaDetect.liveDetect()
        let client = try await resolvedClient(db: db)
        let res = resources?() ?? HostInventoryService.metricsSlice(dataDir: dataDir, hostId: hostId).resources
        return await OllamaLocalProbe.snapshot(
            hostId: hostId,
            displayName: displayName,
            detect: detectResult,
            client: client,
            memoryTotalMB: res.memoryTotalMB,
            memoryUsedMB: res.memoryUsedMB,
            cpuLoadPercent: res.cpuLoadPercent,
        )
    }

    private func resolvedBackend(db: DatabasePool) async throws -> any InferenceBackend {
        if let makeBackend {
            return try await makeBackend(db)
        }
        return try await OllamaInferenceBackend(client: resolvedClient(db: db))
    }

    private func resolvedClient(db: DatabasePool) async throws -> OllamaClient {
        try await db.read { db in
            try OllamaSettings.client(hostId: hostId, from: db)
        }
    }
}
