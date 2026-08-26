import Foundation
import GRDB
import JWTKit
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Unsloth detect")
struct UnslothDetectTests {
    @Test func `mac candidates prefer homebrew then usr local`() {
        let paths = UnslothDetect.candidatePaths(os: "macos")
        #expect(paths.first == "/opt/homebrew/bin/unsloth")
        #expect(paths.contains("/usr/local/bin/unsloth"))
        #expect(!paths.contains("/usr/bin/unsloth"))
        #expect(UnslothDetect.installHint.contains("https://unsloth.ai/install.sh"))
    }

    @Test func `linux candidates include usr bin`() {
        let paths = UnslothDetect.candidatePaths(os: "linux")
        #expect(paths.contains("/usr/local/bin/unsloth"))
        #expect(paths.contains("/usr/bin/unsloth"))
        #expect(!paths.contains("/opt/homebrew/bin/unsloth"))
    }

    @Test func `detect uses injected probe and which fallback`() {
        let missing = UnslothDetect.detect(
            probe: .init(os: "macos", isExecutable: { _ in false }, whichPath: nil),
        )
        #expect(!missing.installed)
        #expect(missing.binaryPath == nil)
        #expect(missing.installHint.contains("unsloth.ai/install.sh"))

        let found = UnslothDetect.detect(
            probe: .init(
                os: "linux",
                isExecutable: { $0 == "/home/me/bin/unsloth" },
                whichPath: "/home/me/bin/unsloth",
            ),
        )
        #expect(found.installed)
        #expect(found.binaryPath == "/home/me/bin/unsloth")
    }
}

@Suite("Inference settings")
struct InferenceSettingsTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    @Test func `default backend is ollama when nothing is stored`() throws {
        let loaded = try dbPool.read { db in
            try InferenceSettings.load(hostId: "desk", from: db)
        }
        #expect(loaded == .ollama)
        let raw = try dbPool.read { db in
            try InferenceSettings.storedRaw(hostId: "desk", from: db)
        }
        #expect(raw == nil)
    }

    @Test func `save and load unsloth through AppSetting`() throws {
        try dbPool.write { db in
            try InferenceSettings.save(.unsloth, hostId: "desk", db: db)
        }
        let loaded = try dbPool.read { db in
            try InferenceSettings.load(hostId: "desk", from: db)
        }
        #expect(loaded == .unsloth)
        let row = try dbPool.read { db in
            try AppSetting.fetchOne(db, key: InferenceSettings.key(hostId: "desk"))?.value
        }
        #expect(row == "unsloth")
        let raw = try dbPool.read { db in
            try InferenceSettings.storedRaw(hostId: "desk", from: db)
        }
        #expect(raw == "unsloth")
    }

    @Test func `unknown stored value fails closed to ollama`() throws {
        try dbPool.write { db in
            try AppSetting(key: InferenceSettings.key(hostId: "desk"), value: "vllm")
                .save(db, onConflict: .replace)
        }
        let loaded = try dbPool.read { db in
            try InferenceSettings.load(hostId: "desk", from: db)
        }
        #expect(loaded == .ollama)
    }

    @Test func `ollama settings snapshot exposes backend`() throws {
        try dbPool.write { db in
            _ = try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: nil,
                updateApiKey: false,
                backend: "unsloth",
                selfHostId: "home",
                db: db,
            )
        }
        let snap = try dbPool.read { db in
            try OllamaSettings.snapshot(hostId: "desk", from: db)
        }
        #expect(snap.backend == "unsloth")
        try dbPool.write { db in
            _ = try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: nil,
                updateApiKey: false,
                backend: "ollama",
                selfHostId: "home",
                db: db,
            )
        }
        let cleared = try dbPool.read { db in
            try OllamaSettings.snapshot(hostId: "desk", from: db)
        }
        #expect(cleared.backend == nil)
    }

    @Test func `settings save without backend leaves the stored kind`() throws {
        try dbPool.write { db in
            _ = try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: nil,
                updateApiKey: false,
                backend: "unsloth",
                selfHostId: "home",
                db: db,
            )
            _ = try OllamaSettings.save(
                hostId: "desk",
                endpoint: "http://127.0.0.1:11434",
                apiKey: nil,
                updateApiKey: false,
                selfHostId: "home",
                db: db,
            )
        }
        let loaded = try dbPool.read { db in
            try InferenceSettings.load(hostId: "desk", from: db)
        }
        #expect(loaded == .unsloth)
    }

    @Test func `settings update encodes backend only when present`() throws {
        let omitted = try String(
            data: JSONEncoder().encode(OllamaSettingsUpdate(hostId: "d")),
            encoding: .utf8,
        )
        #expect(omitted?.contains("backend") != true)
        let explicit = try String(
            data: JSONEncoder().encode(OllamaSettingsUpdate(hostId: "d", backend: "unsloth")),
            encoding: .utf8,
        )
        #expect(explicit?.contains(#""backend":"unsloth""#) == true)
    }

    @Test func `legacy host settings payload still decodes without backend`() throws {
        let legacy = Data(
            #"{"hostId":"d","endpoint":"http://127.0.0.1:11434","hasApiKey":false}"#.utf8,
        )
        let decoded = try JSONDecoder().decode(OllamaHostSettings.self, from: legacy)
        #expect(decoded.backend == nil)
    }
}

@Suite("Unsloth staged models")
struct UnslothStagedModelsTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "unsloth-stage-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `lists files and directories skipping hidden names`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 32).write(to: dir.appendingPathComponent("zeta.gguf"))
        try Data(repeating: 0, count: 4).write(to: dir.appendingPathComponent(".secret.gguf"))
        let sub = dir.appendingPathComponent("alpha-ckpt")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: sub.appendingPathComponent("weights.gguf"))
        try Data(repeating: 0, count: 20).write(to: sub.appendingPathComponent("tokenizer.json"))

        let entries = try UnslothStagedModels.entries(in: dir)
        #expect(entries.map(\.name) == ["alpha-ckpt", "zeta.gguf"])
        #expect(entries.first { $0.name == "zeta.gguf" }?.size == 32)
        #expect(entries.first { $0.name == "alpha-ckpt" }?.size == 30)

        let models = try UnslothStagedModels.models(in: dir, running: "zeta.gguf")
        #expect(models.count == 2)
        #expect(models.first { $0.name == "zeta.gguf" }?.running == true)
        #expect(models.first { $0.name == "alpha-ckpt" }?.running == false)
    }

    @Test func `missing directory yields empty catalog`() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsloth-absent-\(UUID().uuidString)")
        #expect(try UnslothStagedModels.entries(in: missing).isEmpty)
    }
}

@Suite("Unsloth backend")
struct UnslothBackendTests {
    private func isolatedDir(_ label: String = "unsloth-backend") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stage(_ dir: URL, _ name: String, bytes: Int = 16) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: file)
        return file
    }

    private func makeBackend(
        modelsDir: URL,
        transport: RecordingTransport,
        detect: @escaping @Sendable () -> OllamaDetectResult = {
            OllamaDetectResult(installed: true, binaryPath: "/opt/homebrew/bin/unsloth", installHint: "")
        },
        readyTimeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.02,
    ) -> (UnslothInferenceBackend, FakeUnslothSpawner) {
        let spawner = FakeUnslothSpawner()
        let backend = UnslothInferenceBackend(
            modelsDir: modelsDir,
            readyTimeout: readyTimeout,
            pollInterval: pollInterval,
            detect: detect,
            spawner: spawner,
            transport: transport,
        )
        return (backend, spawner)
    }

    private func argValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static let chatBody = Data(#"{"model":"tiny.gguf","stream":false,"messages":[]}"#.utf8)

    @Test func `pull throws unsupported and never spawns`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backend, spawner) = makeBackend(modelsDir: dir, transport: RecordingTransport())
        await #expect(throws: BarkVisorError.self) {
            for try await _ in backend.pull(name: "llama3") {}
        }
        #expect(spawner.spawns.isEmpty)
    }

    @Test func `start spawns unsloth run on loopback with disable tools and api key`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try stage(dir, "tiny.gguf", bytes: 64)
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 200, body: Data(#"{"data":[]}"#.utf8))
        let (backend, spawner) = makeBackend(modelsDir: dir, transport: transport)

        try await backend.start(model: "tiny.gguf")

        #expect(spawner.spawns.count == 1)
        let spawn = try #require(spawner.spawns.first)
        #expect(spawn.executablePath == "/opt/homebrew/bin/unsloth")
        #expect(spawn.arguments.first == "run")
        let spawnedModelPath = try #require(argValue("--model", in: spawn.arguments))
        #expect((spawnedModelPath as NSString).lastPathComponent == staged.lastPathComponent)
        #expect(argValue("-H", in: spawn.arguments) == "127.0.0.1")
        #expect(argValue("-p", in: spawn.arguments) == "18888")
        #expect(spawn.arguments.contains("--disable-tools"))
        let apiKey = try #require(argValue("--api-key", in: spawn.arguments))
        #expect(!apiKey.isEmpty)

        let health = transport.calls.filter { $0.url.path == "/v1/models" }
        #expect(!health.isEmpty)
        #expect(health.allSatisfy { $0.headers["Authorization"] == "Bearer \(apiKey)" })
        #expect(health.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == 18_888 })
    }

    @Test func `stop terminates the child and chat fails closed after`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stage(dir, "tiny.gguf")
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 200, body: Data())
        transport.respond(path: "/v1/chat/completions", status: 200, body: Data(#"{"choices":[]}"#.utf8))
        let (backend, spawner) = makeBackend(modelsDir: dir, transport: transport)

        try await backend.start(model: "tiny.gguf")
        let response = try await backend.chatCompletions(body: Self.chatBody)
        #expect(response.status == 200)

        try await backend.stop(model: "tiny.gguf")
        #expect(spawner.children.first?.terminated == true)
        await #expect(throws: BarkVisorError.self) {
            _ = try await backend.chatCompletions(body: Self.chatBody)
        }
    }

    @Test func `exclusive start of another model stops the first`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stage(dir, "alpha.gguf")
        try stage(dir, "beta.gguf")
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 200, body: Data())
        let (backend, spawner) = makeBackend(modelsDir: dir, transport: transport)

        try await backend.start(model: "alpha.gguf")
        try await backend.start(model: "beta.gguf")

        #expect(spawner.spawns.count == 2)
        #expect(spawner.children.first?.terminated == true)
        let serving = try await backend.catalog()
        #expect(serving.first { $0.name == "beta.gguf" }?.running == true)
        #expect(serving.first { $0.name == "alpha.gguf" }?.running == false)
    }

    @Test func `chat stream hits loopback completions when running`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stage(dir, "tiny.gguf")
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 200, body: Data())
        transport.chunks = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n".utf8)]
        let (backend, _) = makeBackend(modelsDir: dir, transport: transport)

        try await backend.start(model: "tiny.gguf")
        var collected = Data()
        for try await chunk in backend.chatCompletionsStream(body: Self.chatBody) {
            collected.append(chunk)
        }
        #expect(String(data: collected, encoding: .utf8)?.contains("Hi") == true)
        let chat = transport.calls.filter { $0.url.path.hasSuffix("/v1/chat/completions") }
        #expect(chat.count == 1)
        #expect(chat[0].method == "POST")
        #expect(chat[0].url.host == "127.0.0.1")
        #expect(chat[0].url.port == 18_888)
        #expect(chat[0].body == Self.chatBody)
    }

    @Test func `chat fails closed when nothing is running`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backend, spawner) = makeBackend(modelsDir: dir, transport: RecordingTransport())
        await #expect(throws: BarkVisorError.self) {
            _ = try await backend.chatCompletions(body: Self.chatBody)
        }
        await #expect(throws: BarkVisorError.self) {
            for try await _ in backend.chatCompletionsStream(body: Self.chatBody) {}
        }
        #expect(spawner.spawns.isEmpty)
    }

    @Test func `missing binary fails start with the install hint`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stage(dir, "tiny.gguf")
        var thrown: BarkVisorError?
        do {
            try await makeBackend(
                modelsDir: dir,
                transport: RecordingTransport(),
                detect: {
                    OllamaDetectResult(installed: false, binaryPath: nil, installHint: "hint")
                },
            ).0.start(model: "tiny.gguf")
        } catch let error as BarkVisorError {
            thrown = error
        }
        let message = thrown.map { "\($0)" } ?? ""
        #expect(message.contains("unsloth.ai/install.sh"))
    }

    @Test func `start unknown model asks for staging instead of spawning`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backend, spawner) = makeBackend(modelsDir: dir, transport: RecordingTransport())
        await #expect(throws: BarkVisorError.self) {
            try await backend.start(model: "absent.gguf")
        }
        #expect(spawner.spawns.isEmpty)
    }

    @Test func `start timeout terminates the spawned process`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stage(dir, "tiny.gguf")
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 503, body: Data())
        let (backend, spawner) = makeBackend(
            modelsDir: dir,
            transport: transport,
            readyTimeout: 0.15,
            pollInterval: 0.03,
        )
        await #expect(throws: BarkVisorError.self) {
            try await backend.start(model: "tiny.gguf")
        }
        #expect(spawner.spawns.count == 1)
        #expect(spawner.children.first?.terminated == true)
    }

    @Test func `snapshot reports unsloth fields from staged catalog`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stage(dir, "tiny.gguf", bytes: 64)
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 200, body: Data())
        let (backend, _) = makeBackend(modelsDir: dir, transport: transport)

        try await backend.start(model: "tiny.gguf")
        let snap = await backend.snapshot(
            hostId: "self",
            displayName: "lab",
            detectResult: OllamaDetectResult(
                installed: true,
                binaryPath: "/opt/homebrew/bin/unsloth",
                installHint: "",
            ),
            memoryTotalMB: 16_384,
            memoryUsedMB: 2_048,
            cpuLoadPercent: 3,
        )
        #expect(snap.backend == "unsloth")
        #expect(snap.installed)
        #expect(snap.reachable)
        #expect(snap.binaryPath == "/opt/homebrew/bin/unsloth")
        #expect(snap.models.count == 1)
        #expect(snap.models.first?.name == "tiny.gguf")
        #expect(snap.models.first?.running == true)
        #expect(snap.memoryTotalMB == 16_384)

        let down = RecordingTransport()
        down.respond(path: "/v1/models", status: 503, body: Data())
        let cold = makeBackend(modelsDir: dir, transport: down).0
        let coldSnap = await cold.snapshot(
            hostId: "self",
            displayName: nil,
            detectResult: OllamaDetectResult(installed: false, binaryPath: nil, installHint: ""),
            memoryTotalMB: nil,
            memoryUsedMB: nil,
            cpuLoadPercent: nil,
        )
        #expect(coldSnap.reachable == false)
        #expect(coldSnap.backend == "unsloth")
    }

    @Test func `isReachable follows binary install not http`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let down = RecordingTransport()
        down.respond(path: "/v1/models", status: 503, body: Data())
        let (backend, _) = makeBackend(modelsDir: dir, transport: down)
        #expect(await backend.isReachable() == true)
    }
}

@Suite("OllamaController resolved inference backend")
struct OllamaResolvedBackendTests {
    private func isolatedDir(_ label: String = "resolved-backend") throws -> URL {
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

    private func controller(dir: URL, unsloth: UnslothInferenceBackend) -> OllamaController {
        OllamaController(
            backgroundTasks: BackgroundTaskManager(),
            hostId: "self",
            dataDir: dir,
            detect: {
                OllamaDetectResult(installed: true, binaryPath: "/usr/local/bin/ollama", installHint: "brew install ollama")
            },
            resources: {
                ResourcesInfo(cpuCount: 4, memoryTotalMB: 16_384, memoryUsedMB: 2_048, cpuLoadPercent: 3)
            },
            unsloth: unsloth,
            unslothDetect: {
                OllamaDetectResult(
                    installed: true,
                    binaryPath: "/opt/homebrew/bin/unsloth",
                    installHint: UnslothDetect.installHint,
                )
            },
        )
    }

    private func wiredUnsloth(modelsDir: URL, transport: RecordingTransport) -> UnslothInferenceBackend {
        UnslothInferenceBackend(
            modelsDir: modelsDir,
            readyTimeout: 5,
            pollInterval: 0.02,
            detect: {
                OllamaDetectResult(
                    installed: true,
                    binaryPath: "/opt/homebrew/bin/unsloth",
                    installHint: "",
                )
            },
            spawner: FakeUnslothSpawner(),
            transport: transport,
        )
    }

    @Test func `snapshot comes from unsloth when the device setting is unsloth`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelsDir = dir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: modelsDir.appendingPathComponent("tiny.gguf"))
        let transport = RecordingTransport()
        transport.respond(path: "/v1/models", status: 200, body: Data())
        let ctl = controller(dir: dir, unsloth: wiredUnsloth(modelsDir: modelsDir, transport: transport))
        let pool = try migratedPool(dir: dir)
        try await pool.write { db in
            try InferenceSettings.save(.unsloth, hostId: "self", db: db)
        }

        let snap = try await ctl.currentSnapshot(db: pool)
        #expect(snap.backend == "unsloth")
        #expect(snap.installed)
        #expect(snap.binaryPath == "/opt/homebrew/bin/unsloth")
        #expect(snap.models.map(\.name) == ["tiny.gguf"])

        let status = try await ctl.start(
            body: OllamaModelActionRequest(name: "tiny.gguf"),
            db: pool,
        )
        #expect(status == HTTPStatus.noContent)
    }

    @Test func `snapshot stays ollama when the device setting is ollama`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = controller(dir: dir, unsloth: wiredUnsloth(
            modelsDir: dir,
            transport: RecordingTransport(),
        ))
        let pool = try migratedPool(dir: dir)

        let snap = try await ctl.currentSnapshot(db: pool)
        #expect(snap.backend == nil)
        #expect(snap.installHint == "brew install ollama")
    }

    @Test func `unreachable copy names the active backend`() {
        let unsloth = OllamaController.unreachableError(backendId: "unsloth").errorDescription ?? ""
        #expect(unsloth.contains("Unsloth"))
        #expect(unsloth.contains("unsloth.ai/install.sh"))
        let ollama = OllamaController.unreachableError(backendId: "ollama").errorDescription ?? ""
        #expect(ollama == "Ollama is not reachable on this Device")
    }
}

@Suite("HomeOllama backend setting round-trip")
struct HomeOllamaBackendSettingTests {
    private func isolatedDir(_ label: String = "home-unsloth") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func adminUser() -> AuthenticatedUser {
        AuthenticatedUser(
            userId: "admin-1",
            username: "admin",
            authMethod: "jwt",
            apiKeyId: nil,
            role: UserRole.admin.rawValue,
        )
    }

    @Test func `put settings stores backend locally and get returns it`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let ctl = HomeOllamaController(
            backgroundTasks: BackgroundTaskManager(),
            dataDir: dir,
            hostId: "home",
            localOllama: OllamaController(backgroundTasks: BackgroundTaskManager(), hostId: "home", dataDir: dir),
        )

        let saved = try await ctl.putSettings(
            body: OllamaSettingsUpdate(hostId: "home", backend: "unsloth"),
            db: pool,
            user: adminUser(),
        )
        #expect(saved.host("home")?.backend == "unsloth")

        let listed = try await ctl.listSettings(db: pool)
        #expect(listed.host("home")?.backend == "unsloth")

        let stored = try await pool.read { db in
            try InferenceSettings.load(hostId: "home", from: db)
        }
        #expect(stored == .unsloth)

        _ = try await ctl.putSettings(
            body: OllamaSettingsUpdate(hostId: "home", backend: "ollama"),
            db: pool,
            user: adminUser(),
        )
        let reset = try await ctl.listSettings(db: pool)
        #expect(reset.host("home")?.backend == nil)
    }

    @Test func `put settings pushes backend to member devices`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let peerId = "peer-desk"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "ff", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = SettingsProxyRecorder()
        client.respond(path: "/api/ollama/settings", status: 200, body: Data())
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "unsloth-hop-secret"), digestAlgorithm: .sha256)
        let ctl = HomeOllamaController(
            backgroundTasks: BackgroundTaskManager(),
            dataDir: dir,
            hostId: "home",
            devices: store,
            mtlsClient: client,
            localOllama: OllamaController(backgroundTasks: BackgroundTaskManager(), hostId: "home", dataDir: dir),
            keys: keys,
        )

        let snapshot = try await ctl.putSettings(
            body: OllamaSettingsUpdate(hostId: peerId, backend: "unsloth"),
            db: pool,
            user: adminUser(),
        )
        #expect(snapshot.host(peerId)?.backend == "unsloth")

        let put = client.calls.first { $0.method == "PUT" && $0.url.path == "/api/ollama/settings" }
        let object = try JSONSerialization.jsonObject(with: put?.body ?? Data()) as? [String: Any]
        #expect(object?["backend"] as? String == "unsloth")
        #expect(object?["hostId"] as? String == peerId)
    }
}

private final class SettingsProxyRecorder: HomeDeviceProxyClient, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var body: Data
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [String: HomeDeviceProxyResponse] = [:]

    var calls: [Call] {
        lock.withLock { _calls }
    }

    func respond(path: String, status: Int, body: Data) {
        lock.withLock { responses[path] = HomeDeviceProxyResponse(status: status, body: body) }
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        let recorded = Call(method: request.method, url: request.url, body: request.body ?? Data())
        return lock.withLock {
            _calls.append(recorded)
            return responses[request.url.path] ?? HomeDeviceProxyResponse(status: 404, body: Data())
        }
    }

    func stream(_ request: HomeDeviceProxyRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class RecordingTransport: OllamaHTTPTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [String: OllamaHTTPResponse] = [:]
    var chunks: [Data] = []

    var calls: [Call] {
        lock.withLock { _calls }
    }

    func respond(path: String, status: Int, body: Data) {
        lock.withLock { responses[path] = OllamaHTTPResponse(status: status, body: body) }
    }

    func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
    ) async throws -> OllamaHTTPResponse {
        let recorded = Call(method: method, url: url, headers: headers, body: body ?? Data())
        return lock.withLock {
            _calls.append(recorded)
            return responses[url.path] ?? OllamaHTTPResponse(status: 404, body: Data())
        }
    }

    func stream(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
    ) -> AsyncThrowingStream<Data, Error> {
        let recorded = Call(method: method, url: url, headers: headers, body: body ?? Data())
        let chunks: [Data] = lock.withLock {
            _calls.append(recorded)
            return self.chunks
        }
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private final class FakeUnslothSpawner: UnslothProcessSpawner, @unchecked Sendable {
    struct Spawn {
        var executablePath: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private var _spawns: [Spawn] = []
    private var _children: [FakeUnslothChild] = []

    var spawns: [Spawn] {
        lock.withLock { _spawns }
    }

    var children: [FakeUnslothChild] {
        lock.withLock { _children }
    }

    func spawn(executablePath: String, arguments: [String]) throws -> any UnslothChildProcess {
        lock.withLock {
            _spawns.append(Spawn(executablePath: executablePath, arguments: arguments))
            let child = FakeUnslothChild()
            _children.append(child)
            return child
        }
    }
}

private final class FakeUnslothChild: UnslothChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminated = false

    var terminated: Bool {
        lock.withLock { _terminated }
    }

    func terminate() {
        lock.withLock { _terminated = true }
    }

    func killAfterGrace(_: TimeInterval) async {}
}
