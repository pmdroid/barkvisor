import Foundation
import GRDB
import JWTKit
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home Ollama member hop (PAS-286)")
struct HomeOllamaControllerTests {
    private func isolatedDir(_ label: String = "home-ollama") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeKeys() async -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "pas-286-hop-secret"), digestAlgorithm: .sha256)
        return keys
    }

    private func controller(
        dir: URL,
        hostId: String,
        devices: DeviceRegistry,
        client: RecordingOllamaProxyClient,
        keys: JWTKeyCollection,
        now: Date,
    ) -> HomeOllamaController {
        HomeOllamaController(
            backgroundTasks: BackgroundTaskManager(),
            dataDir: dir,
            hostId: hostId,
            devices: devices,
            mtlsClient: client,
            localOllama: OllamaController(
                backgroundTasks: BackgroundTaskManager(),
                hostId: hostId,
                dataDir: dir,
            ),
            keys: keys,
            now: { now },
        )
    }

    @Test func `member hop mints a Home JWT instead of forwarding an API key`() async throws {
        let dir = try isolatedDir("hop-jwt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = UUID().uuidString
        let peerId = "peer-desk"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "aa", agentHost: "10.0.0.8", agentPort: 7_778)
        let snapshot = OllamaDeviceSnapshot(
            hostId: peerId,
            displayName: "desk",
            installed: true,
            reachable: true,
            installHint: "brew",
            probedAt: "2026-01-01T00:00:00Z",
            models: [OllamaLocalModel(name: "llama3:latest", size: 100, running: true)],
        )
        let client = RecordingOllamaProxyClient()
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/ollama/snapshot",
            status: 200,
            body: JSONEncoder().encode(snapshot),
        )
        let keys = await makeKeys()
        let now = Date()
        let ctl = controller(
            dir: dir, hostId: selfId, devices: store, client: client, keys: keys, now: now,
        )
        let user = AuthenticatedUser(
            userId: "admin-1",
            username: "admin",
            authMethod: "apikey",
            apiKeyId: "key-1",
            apiKeyKind: APIKeyKind.inference.rawValue,
            role: UserRole.admin.rawValue,
        )
        let result = try await ctl.sendMember(
            hostId: peerId,
            method: "GET",
            path: "/api/ollama/snapshot",
            body: nil,
            user: user,
        )
        #expect(result.status == 200)
        #expect(client.calls.count == 1)
        let auth = header("Authorization", in: client.calls[0].headers) ?? ""
        #expect(auth.hasPrefix("Bearer "))
        let token = String(auth.dropFirst("Bearer ".count))
        #expect(!token.hasPrefix("barkvisor_"))
        let payload = try await keys.verify(token, as: UserPayload.self)
        #expect(payload.sub.value == "admin-1")
        #expect(payload.role == UserRole.inference.rawValue)
        #expect(
            abs(
                payload.exp.value.timeIntervalSince1970
                    - now.addingTimeInterval(AuthService.memberHopTokenTTL).timeIntervalSince1970,
            ) < 1,
        )
    }

    @Test func `probeMember maps member models when the caller is an API key`() async throws {
        let dir = try isolatedDir("probe-key")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selfId = UUID().uuidString
        let peerId = "peer-desk"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "bb", agentHost: "10.0.0.8", agentPort: 7_778)
        let snapshot = OllamaDeviceSnapshot(
            hostId: peerId,
            displayName: "desk",
            installed: true,
            reachable: true,
            installHint: "brew",
            probedAt: "2026-01-01T00:00:00Z",
            models: [OllamaLocalModel(name: "phi3:latest", size: 50, running: false)],
        )
        let client = RecordingOllamaProxyClient()
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/ollama/snapshot",
            status: 200,
            body: JSONEncoder().encode(snapshot),
        )
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir, hostId: selfId, devices: store, client: client, keys: keys, now: Date(),
        )
        let hop = try await ctl.memberHopBearer(
            for: AuthenticatedUser(
                userId: "admin-1",
                username: "admin",
                authMethod: "apikey",
                apiKeyId: "key-full",
                apiKeyKind: APIKeyKind.full.rawValue,
                role: UserRole.admin.rawValue,
            ),
        )
        let probed = await ctl.probeMember(
            HomeDevice(
                hostId: peerId,
                role: "member",
                displayName: "desk",
                agentHost: "10.0.0.8",
                agentPort: 7_778,
            ),
            hopBearer: hop,
        )
        #expect(probed?.reachable == true)
        #expect(probed?.models.contains { $0.name == "phi3:latest" } == true)
        let auth = header("Authorization", in: client.calls[0].headers) ?? ""
        let token = String(auth.dropFirst("Bearer ".count))
        let payload = try await keys.verify(token, as: UserPayload.self)
        #expect(payload.role == UserRole.admin.rawValue)
        #expect(!token.hasPrefix("barkvisor_"))
    }

    @Test func `sendMemberStream forwards chat SSE without collecting in the controller`() async throws {
        let dir = try isolatedDir("chat-stream")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: "peer", fingerprint: "dd", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = RecordingOllamaProxyClient()
        let sse = Data(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#.utf8)
        client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/ollama/v1/chat/completions",
            status: 200,
            body: sse,
        )
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir,
            hostId: UUID().uuidString,
            devices: store,
            client: client,
            keys: keys,
            now: Date(),
        )
        var collected = Data()
        for try await chunk in try ctl.sendMemberStream(
            hostId: "peer",
            method: "POST",
            path: "/api/ollama/v1/chat/completions",
            body: Data(#"{"model":"llama3","stream":true}"#.utf8),
            hopBearer: "jwt-hop",
        ) {
            collected.append(chunk)
        }
        #expect(client.streamCalls == 1)
        #expect(collected == sse)
        #expect(client.calls[0].method == "POST")
    }

    @Test func `sendMemberStream refuses to forward an API key to a member Device`() async throws {
        let dir = try isolatedDir("no-apikey-stream")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: "peer", fingerprint: "ee", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = RecordingOllamaProxyClient()
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir,
            hostId: UUID().uuidString,
            devices: store,
            client: client,
            keys: keys,
            now: Date(),
        )
        #expect(throws: BarkVisorError.self) {
            _ = try ctl.sendMemberStream(
                hostId: "peer",
                method: "POST",
                path: "/api/ollama/v1/chat/completions",
                body: Data(),
                hopBearer: "barkvisor_testkey",
            )
        }
        #expect(client.calls.isEmpty)
        #expect(client.streamCalls == 0)
    }

    @Test func `probeMember and sendMember distinguish hop timeout from Ollama HTTP 5xx`() async throws {
        let dir = try isolatedDir("hop-codes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let timeoutId = "timeout-peer"
        let httpId = "http-peer"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: timeoutId, fingerprint: "aa", agentHost: "10.0.0.6", agentPort: 7_778)
        try store.upsert(hostId: httpId, fingerprint: "bb", agentHost: "10.0.0.7", agentPort: 7_778)
        let client = RecordingOllamaProxyClient()
        client.fail(
            host: "10.0.0.6",
            port: 7_778,
            path: "/api/ollama/snapshot",
            error: HomeDeviceProxyError.connectTimeout,
        )
        client.respond(
            host: "10.0.0.7",
            port: 7_778,
            path: "/api/ollama/snapshot",
            status: 503,
            body: Data("nope".utf8),
        )
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir,
            hostId: UUID().uuidString,
            devices: store,
            client: client,
            keys: keys,
            now: Date(),
        )
        let timedOut = await ctl.probeMember(
            HomeDevice(
                hostId: timeoutId,
                role: "member",
                displayName: "desk",
                agentHost: "10.0.0.6",
                agentPort: 7_778,
            ),
            hopBearer: "jwt-hop",
        )
        #expect(timedOut?.reachable == false)
        #expect(timedOut?.installHint == HomeDeviceProxyError.connectTimeout.ollamaHopDescription)
        #expect(timedOut?.installHint.contains("Home cannot hop") == true)

        let http = await ctl.probeMember(
            HomeDevice(
                hostId: httpId,
                role: "member",
                displayName: "studio",
                agentHost: "10.0.0.7",
                agentPort: 7_778,
            ),
            hopBearer: "jwt-hop",
        )
        #expect(http?.reachable == false)
        #expect(http?.installHint == "Ollama is down on the Device (HTTP 503)")

        await #expect(throws: BarkVisorError.self) {
            try await ctl.sendMember(
                hostId: timeoutId,
                method: "GET",
                path: "/api/ollama/snapshot",
                body: nil,
                hopBearer: "jwt-hop",
            )
        }
        do {
            _ = try await ctl.sendMember(
                hostId: timeoutId,
                method: "GET",
                path: "/api/ollama/snapshot",
                body: nil,
                hopBearer: "jwt-hop",
            )
            Issue.record("expected sendMember connectTimeout to throw")
        } catch let error as BarkVisorError {
            #expect(error.httpStatus == 502)
            #expect(error.sanitizedDescription.contains("Home cannot hop"))
            #expect(!error.sanitizedDescription.hasPrefix("Device is unreachable:"))
        }
    }

    @Test func `sendMember refuses to forward an API key to a member Device`() async throws {
        let dir = try isolatedDir("no-apikey")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: "peer", fingerprint: "cc", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = RecordingOllamaProxyClient()
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir,
            hostId: UUID().uuidString,
            devices: store,
            client: client,
            keys: keys,
            now: Date(),
        )
        await #expect(throws: BarkVisorError.self) {
            try await ctl.sendMember(
                hostId: "peer",
                method: "GET",
                path: "/api/ollama/snapshot",
                body: nil,
                hopBearer: "barkvisor_testkey",
            )
        }
        #expect(client.calls.isEmpty)
    }

    @Test func `put settings stores on Home and pushes the key to the Device`() async throws {
        let dir = try isolatedDir("settings-fanout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let selfId = UUID().uuidString
        let peerId = "peer-desk"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "ff", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = RecordingOllamaProxyClient()
        try client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/ollama/settings",
            status: 200,
            body: JSONEncoder().encode(OllamaSettingsSnapshot(hosts: [])),
        )
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir, hostId: selfId, devices: store, client: client, keys: keys, now: Date(),
        )
        let user = AuthenticatedUser(
            userId: "admin-1",
            username: "admin",
            authMethod: "jwt",
            apiKeyId: nil,
            role: UserRole.admin.rawValue,
        )
        let snapshot = try await ctl.putSettings(
            body: OllamaSettingsUpdate(hostId: peerId, apiKey: "peer-secret"),
            db: pool,
            user: user,
        )
        #expect(snapshot.host(peerId)?.hasApiKey == true)
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!text.contains("peer-secret"))
        #expect(client.calls.contains { $0.method == "PUT" })
        let stored = try await pool.read { db in
            try OllamaSettings.load(hostId: peerId, from: db).apiKey
        }
        #expect(stored == "peer-secret")
    }

    @Test func `put settings does not store on Home when the Device hop fails`() async throws {
        let dir = try isolatedDir("settings-fanout-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let selfId = UUID().uuidString
        let peerId = "peer-desk"
        let store = DeviceRegistry(dataDir: dir)
        try store.upsert(hostId: peerId, fingerprint: "ff", agentHost: "10.0.0.8", agentPort: 7_778)
        let client = RecordingOllamaProxyClient()
        client.respond(
            host: "10.0.0.8",
            port: 7_778,
            path: "/api/ollama/settings",
            status: 502,
            body: Data(),
        )
        let keys = await makeKeys()
        let ctl = controller(
            dir: dir, hostId: selfId, devices: store, client: client, keys: keys, now: Date(),
        )
        let user = AuthenticatedUser(
            userId: "admin-1",
            username: "admin",
            authMethod: "jwt",
            apiKeyId: nil,
            role: UserRole.admin.rawValue,
        )
        await #expect(throws: BarkVisorError.self) {
            try await ctl.putSettings(
                body: OllamaSettingsUpdate(hostId: peerId, apiKey: "peer-secret"),
                db: pool,
                user: user,
            )
        }
        #expect(client.calls.contains { $0.method == "PUT" })
        let stored = try await pool.read { db in
            try OllamaHostSettingRecord.fetch(db, hostId: peerId)?.apiKey
        }
        #expect(stored == nil)
        let loaded = try await pool.read { db in
            try OllamaSettings.load(hostId: peerId, from: db).apiKey
        }
        #expect(loaded == nil)
    }

    @Test func `local pull start stop pass decoded body instead of the consumed request`() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/BarkVisor/Server/Controllers/HomeOllamaController.swift",
            ),
            encoding: .utf8,
        )
        #expect(source.contains("localOllama.pull(body: body, db: req.db)"))
        #expect(source.contains("localOllama.start(body: body, db: req.db)"))
        #expect(source.contains("localOllama.stop(body: body, db: req.db)"))
        #expect(!source.contains("localOllama.pull(req: req)"))
        #expect(!source.contains("localOllama.start(req: req)"))
        #expect(!source.contains("localOllama.stop(req: req)"))
        #expect(source.contains("Self.runningSizeVRAM(selfHostId: selfHostId, locations: $0.locations)"))
        #expect(!source.contains("locations.first(where: \\.running)?.sizeVRAM"))
    }
}

@Suite("Home Ollama native sizeVRAM")
struct HomeOllamaNativeSizeVRAMTests {
    private func location(_ hostId: String, running: Bool, sizeVRAM: Int64?) -> OllamaModelLocation {
        OllamaModelLocation(
            hostId: hostId,
            running: running,
            reachable: true,
            probedAt: "2026-01-01T00:00:00Z",
            sizeVRAM: sizeVRAM,
        )
    }

    @Test func `prefers self when running else lowest hostId`() {
        let disordered = [
            location("zeta", running: true, sizeVRAM: 9),
            location("alpha", running: true, sizeVRAM: 1),
            location("self", running: false, sizeVRAM: 50),
        ]
        #expect(
            HomeOllamaController.runningSizeVRAM(selfHostId: "self", locations: disordered) == 1,
        )

        let withSelfRunning = disordered + [
            location("self", running: true, sizeVRAM: 7),
        ]
        #expect(
            HomeOllamaController.runningSizeVRAM(selfHostId: "self", locations: withSelfRunning)
                == 7,
        )
        #expect(HomeOllamaController.runningSizeVRAM(selfHostId: "self", locations: []) == nil)
        #expect(
            HomeOllamaController.runningSizeVRAM(
                selfHostId: "self",
                locations: [location("lab", running: false, sizeVRAM: 3)],
            ) == nil,
        )
    }
}

private func header(_ name: String, in headers: [(String, String)]) -> String? {
    headers.first { $0.0.lowercased() == name.lowercased() }?.1
}

private final class RecordingOllamaProxyClient: HomeDeviceProxyClient, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var headers: [(String, String)]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _streamCalls = 0
    private var responses: [String: Result<HomeDeviceProxyResponse, Error>] = [:]

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var streamCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _streamCalls
    }

    func respond(host: String, port: Int, path: String, status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(host):\(port)\(path)"] = .success(
            HomeDeviceProxyResponse(status: status, body: body),
        )
    }

    func fail(host: String, port: Int, path: String, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(host):\(port)\(path)"] = .failure(error)
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        switch record(request) {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        case nil:
            return HomeDeviceProxyResponse(status: 404, body: Data())
        }
    }

    func stream(_ request: HomeDeviceProxyRequest) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        _streamCalls += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(request)
                    if !(200 ..< 300).contains(response.status) {
                        continuation.finish(throwing: BarkVisorError.badGateway("HTTP \(response.status)"))
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

    private func record(_ request: HomeDeviceProxyRequest) -> Result<HomeDeviceProxyResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(Call(method: request.method, url: request.url, headers: request.headers))
        return responses["\(request.url.host ?? ""):\(request.url.port ?? 0)\(request.url.path)"]
    }
}
