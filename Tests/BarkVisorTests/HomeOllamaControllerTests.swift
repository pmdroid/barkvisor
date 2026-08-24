import Foundation
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
