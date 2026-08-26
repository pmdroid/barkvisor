import Foundation
import GRDB
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("InferenceBackend seam")
struct InferenceBackendTests {
    private func isolatedDir(_ label: String = "inference-seam") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func migratedPool(dir: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }

    private func backend(_ transport: RecordingTransport) throws -> OllamaInferenceBackend {
        try OllamaInferenceBackend(
            client: OllamaClient(
                baseURL: #require(URL(string: "http://127.0.0.1:11434")),
                transport: transport,
            ),
        )
    }

    private func seamController(backend: FakeInferenceBackend, dir: URL) -> OllamaController {
        OllamaController(
            backgroundTasks: BackgroundTaskManager(),
            hostId: "self",
            dataDir: dir,
            makeBackend: { _ in backend },
            detect: { OllamaDetectResult(installed: true, binaryPath: nil, installHint: "") },
            resources: {
                ResourcesInfo(cpuCount: 4, memoryTotalMB: 16_384, memoryUsedMB: 2_048, cpuLoadPercent: 3)
            },
        )
    }

    @Test func `backend identifies as ollama`() throws {
        #expect(try backend(RecordingTransport()).backendId == "ollama")
    }

    @Test func `buffered chat posts to the completions path`() async throws {
        let transport = RecordingTransport()
        transport.respond(path: "/v1/chat/completions", status: 200, body: Data(#"{"choices":[]}"#.utf8))
        let body = Data(#"{"model":"llama3","stream":false,"messages":[]}"#.utf8)
        let response = try await backend(transport).chatCompletions(body: body)
        #expect(response.status == 200)
        #expect(transport.calls.count == 1)
        #expect(transport.calls[0].method == "POST")
        #expect(transport.calls[0].url.path.hasSuffix("/v1/chat/completions"))
        #expect(transport.calls[0].body == body)
    }

    @Test func `streaming chat uses the byte stream`() async throws {
        let transport = RecordingTransport()
        transport.chunks = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n".utf8)]
        var collected = Data()
        let seam = try backend(transport)
        for try await chunk in seam.chatCompletionsStream(body: Data(#"{"model":"m"}"#.utf8)) {
            collected.append(chunk)
        }
        #expect(String(data: collected, encoding: .utf8)?.contains("Hi") == true)
        #expect(transport.calls.count == 1)
        #expect(transport.calls[0].url.path.hasSuffix("/v1/chat/completions"))
    }

    @Test func `start and stop drive generate keep_alive`() async throws {
        let transport = RecordingTransport()
        transport.respond(path: "/api/generate", status: 200, body: Data("{}".utf8))
        let seam = try backend(transport)
        try await seam.start(model: "llama3")
        try await seam.stop(model: "llama3")
        #expect(transport.calls.count == 2)
        let startObject = try JSONSerialization.jsonObject(with: transport.calls[0].body) as? [String: Any]
        #expect(startObject?["model"] as? String == "llama3")
        #expect(startObject?["keep_alive"] as? String == "5m")
        let stopObject = try JSONSerialization.jsonObject(with: transport.calls[1].body) as? [String: Any]
        #expect(stopObject?["model"] as? String == "llama3")
        #expect(stopObject?["keep_alive"] as? Int == 0)
    }

    @Test func `catalog merges tags and running models`() async throws {
        let transport = RecordingTransport()
        transport.respond(
            path: "/api/tags",
            status: 200,
            body: Data(
                #"{"models":[{"name":"llama3:latest","size":100,"details":{"parameter_size":"8B"}}]}"#
                    .utf8,
            ),
        )
        transport.respond(
            path: "/api/ps",
            status: 200,
            body: Data(#"{"models":[{"name":"llama3:latest","size_vram":42}]}"#.utf8),
        )
        let models = try await backend(transport).catalog()
        #expect(models.count == 1)
        #expect(models[0].name == "llama3:latest")
        #expect(models[0].size == 100)
        #expect(models[0].running == true)
        #expect(models[0].sizeVRAM == 42)
        #expect(models[0].parameterSize == "8B")
    }

    @Test func `pull decodes streamed progress events`() async throws {
        let transport = RecordingTransport()
        transport.chunks = [
            Data("{\"status\":\"pulling manifest\"}\n".utf8),
            Data("{\"status\":\"downloading\",\"digest\":\"sha256:x\",\"total\":10,\"completed\":4}\n".utf8),
            Data("{\"status\":\"success\"}\n".utf8),
        ]
        var events: [OllamaPullEvent] = []
        let seam = try backend(transport)
        for try await event in seam.pull(name: "llama3") {
            events.append(event)
        }
        #expect(events.count == 3)
        #expect(events[1].fraction == 0.4)
        #expect(transport.calls.count == 1)
        #expect(transport.calls[0].method == "POST")
        #expect(transport.calls[0].url.path.hasSuffix("/api/pull"))
    }

    @Test func `reachability probes the version endpoint`() async throws {
        let up = RecordingTransport()
        up.respond(path: "/api/version", status: 200, body: Data())
        let down = RecordingTransport()
        down.respond(path: "/api/version", status: 503, body: Data())
        let upBackend = try backend(up)
        let downBackend = try backend(down)
        #expect(await upBackend.isReachable() == true)
        #expect(await downBackend.isReachable() == false)
    }

    @Test func `buffered completions run through the injected backend`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeInferenceBackend()
        let ctl = seamController(backend: fake, dir: dir)
        let body = Data(#"{"model":"llama3","stream":false,"messages":[]}"#.utf8)
        let response = try await ctl.complete(body: body, db: migratedPool(dir: dir))
        #expect(response.status.code == 200)
        #expect(fake.chatBodies == [body])
        #expect(fake.streamBodies.isEmpty)
    }

    @Test func `streaming completions run through the injected backend`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeInferenceBackend()
        let ctl = seamController(backend: fake, dir: dir)
        let body = Data(#"{"model":"llama3","stream":true,"messages":[]}"#.utf8)
        let response = try await ctl.complete(body: body, db: migratedPool(dir: dir))
        #expect(response.status.code == 200)
        #expect(response.headers.first(name: .contentType) == "text/event-stream")
        #expect(fake.streamBodies == [body])
        #expect(fake.chatBodies.isEmpty)
    }

    @Test func `start loads through the injected backend`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeInferenceBackend()
        let ctl = seamController(backend: fake, dir: dir)
        let status = try await ctl.start(
            body: OllamaModelActionRequest(name: "llama3"),
            db: migratedPool(dir: dir),
        )
        #expect(status == HTTPStatus.noContent)
        #expect(fake.startedModels == ["llama3"])
    }

    @Test func `stop unloads through the injected backend`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeInferenceBackend()
        let ctl = seamController(backend: fake, dir: dir)
        let status = try await ctl.stop(
            body: OllamaModelActionRequest(name: "llama3"),
            db: migratedPool(dir: dir),
        )
        #expect(status == HTTPStatus.noContent)
        #expect(fake.stoppedModels == ["llama3"])
    }

    @Test func `pull streams through the injected backend`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeInferenceBackend()
        let ctl = seamController(backend: fake, dir: dir)
        let accepted = try await ctl.pull(
            body: OllamaPullRequest(name: "llama3"),
            db: migratedPool(dir: dir),
        )
        #expect(accepted.hostId == "self")
        #expect(!accepted.taskID.isEmpty)
        for _ in 0 ..< 80 {
            if !fake.pulledNames.isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(fake.pulledNames == ["llama3"])
    }

    @Test func `pull fails closed when the backend is unreachable`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeInferenceBackend()
        fake.isReachableResult = false
        let ctl = seamController(backend: fake, dir: dir)
        await #expect(throws: BarkVisorError.self) {
            _ = try await ctl.pull(
                body: OllamaPullRequest(name: "llama3"),
                db: migratedPool(dir: dir),
            )
        }
        #expect(fake.pulledNames.isEmpty)
    }
}

private final class RecordingTransport: OllamaHTTPTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var body: Data
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [String: OllamaHTTPResponse] = [:]
    var chunks: [Data] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func respond(path: String, status: Int, body: Data) {
        lock.lock()
        responses[path] = OllamaHTTPResponse(status: status, body: body)
        lock.unlock()
    }

    func send(method: String, url: URL, headers _: [String: String], body: Data?) async throws
        -> OllamaHTTPResponse {
        record(method: method, url: url, body: body)
        return response(for: url.path)
    }

    func stream(method: String, url: URL, headers _: [String: String], body: Data?)
        -> AsyncThrowingStream<Data, Error> {
        record(method: method, url: url, body: body)
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    private func record(method: String, url: URL, body: Data?) {
        lock.lock()
        _calls.append(Call(method: method, url: url, body: body ?? Data()))
        lock.unlock()
    }

    private func response(for path: String) -> OllamaHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        return responses[path] ?? OllamaHTTPResponse(status: 404, body: Data())
    }
}

private final class FakeInferenceBackend: InferenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _chatBodies: [Data] = []
    private var _streamBodies: [Data] = []
    private var _startedModels: [String] = []
    private var _stoppedModels: [String] = []
    private var _pulledNames: [String] = []

    var isReachableResult = true
    var chatResponse = OllamaHTTPResponse(
        status: 200,
        body: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
    )
    var streamChunks = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n".utf8)]
    var pullEvents = [OllamaPullEvent(status: "success")]

    var chatBodies: [Data] {
        locked { _chatBodies }
    }

    var streamBodies: [Data] {
        locked { _streamBodies }
    }

    var startedModels: [String] {
        locked { _startedModels }
    }

    var stoppedModels: [String] {
        locked { _stoppedModels }
    }

    var pulledNames: [String] {
        locked { _pulledNames }
    }

    var backendId: String {
        "fake"
    }

    func catalog() async throws -> [OllamaLocalModel] {
        []
    }

    func pull(name: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        lock.lock()
        _pulledNames.append(name)
        lock.unlock()
        let events = pullEvents
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func start(model: String) async throws {
        record(started: model)
    }

    func stop(model: String) async throws {
        record(stopped: model)
    }

    func chatCompletions(body: Data) async throws -> OllamaHTTPResponse {
        record(chat: body)
        return chatResponse
    }

    func chatCompletionsStream(body: Data) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        _streamBodies.append(body)
        lock.unlock()
        let chunks = streamChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func isReachable() async -> Bool {
        isReachableResult
    }

    private func record(started: String) {
        lock.lock()
        _startedModels.append(started)
        lock.unlock()
    }

    private func record(stopped: String) {
        lock.lock()
        _stoppedModels.append(stopped)
        lock.unlock()
    }

    private func record(chat body: Data) {
        lock.lock()
        _chatBodies.append(body)
        lock.unlock()
    }

    private func locked<T>(_ value: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return value()
    }
}
