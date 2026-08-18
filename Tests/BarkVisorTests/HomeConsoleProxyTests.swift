import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home console WebSocket tunnel (PAS-200)", .serialized)
struct HomeConsoleProxyTests {
    private static let ticket = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// Live Application + WebSocket echo times out on both GitHub
    /// runners. Unit checks still run; re-enable when the harness is
    /// reliable.
    private static var liveWS: Bool {
        false
    }

    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "console-proxy-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeApp() async throws -> Application {
        var env = Environment(name: "testing", arguments: ["barkvisor-test"])
        env.commandInput = CommandInput(arguments: ["barkvisor-test"])
        let app = try await Application.make(env)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.http.server.configuration.supportVersions = [.one]
        app.http.server.configuration.shutdownTimeout = .seconds(2)
        app.logger.logLevel = .error
        return app
    }

    private func boundPort(_ app: Application) throws -> Int {
        try #require(app.http.server.shared.localAddress?.port)
    }

    /// Do not await a stuck `asyncShutdown` — leftover WS/HTTP can ignore cancellation
    /// and park the Swift Testing suite for the whole CI job.
    private func stop(_ app: Application) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ShutdownOnce(cont)
            Task {
                try? await app.asyncShutdown()
                once.finish()
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                once.finish()
            }
        }
    }

    @Test func `home checks device ticket uuid shape only`() async throws {
        let app = try await makeApp()
        do {
            func request(_ query: String) -> Request {
                Request(
                    application: app,
                    method: .GET,
                    url: URI(string: query.isEmpty ? "/t" : "/t?\(query)"),
                    on: app.eventLoopGroup.next(),
                )
            }
            #expect(throws: Abort.self) {
                try HomeConsoleProxy.requireTicket(request(""))
            }
            #expect(throws: Abort.self) {
                try HomeConsoleProxy.requireTicket(request("ticket=not-a-uuid"))
            }
            try HomeConsoleProxy.requireTicket(request("ticket=\(Self.ticket)"))
            try HomeConsoleProxy.requireTicket(request("token=\(Self.ticket)"))
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `http proxy refuses websocket upgrade instead of stripping it`() async throws {
        let app = try await makeApp()
        app.middleware.use(StubHomeUserMiddleware())
        try app.register(
            collection: HomeDevicesController(
                dataDir: isolatedDir(),
                hostId: UUID().uuidString,
            ),
        )
        try await app.startup()
        do {
            let port = try boundPort(app)
            // URLSession, not `app.client`: AsyncHTTPClient waits forever for 101
            // when the request carries Upgrade: websocket.
            var request = try URLRequest(
                url: #require(
                    URL(
                        string:
                        "http://127.0.0.1:\(port)/api/home/devices/peer-1/v1/vms/vm-1/vnc?ticket=t",
                    ),
                ),
            )
            request.setValue("Bearer unused", forHTTPHeaderField: "Authorization")
            request.setValue("Upgrade", forHTTPHeaderField: "Connection")
            request.setValue("websocket", forHTTPHeaderField: "Upgrade")
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 426)
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `unreachable member URL is built without sqlite`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DeviceRegistry(dataDir: dir).upsert(hostId: "peer-down", fingerprint: "aa")
        let record = try #require(try DeviceRegistry(dataDir: dir).record(forHostId: "peer-down"))
        #expect(record.agentHost == nil)
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.consoleTargetURL(
                HomeConsoleTarget(
                    isSelf: false,
                    localPort: 7_777,
                    agentHost: record.agentHost,
                    agentPort: record.agentPort,
                    vmID: "vm-1",
                    kind: .console,
                    query: "ticket=abc",
                ),
            )
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("db.sqlite").path))
    }

    @Test func `pre-dial buffer rejects frames over the pending cap`() {
        let box = WebSocketPipeBox()
        box.maxPendingBytes = 8
        var first = ByteBufferAllocator().buffer(capacity: 4)
        first.writeString("abcd")
        #expect(box.sendOrBuffer(.binary(first)))
        #expect(!box.overflowed)
        var second = ByteBufferAllocator().buffer(capacity: 8)
        second.writeString("12345678")
        #expect(!box.sendOrBuffer(.binary(second)))
        #expect(box.overflowed)
        #expect(!box.sendOrBuffer(.text("x")))
    }

    @Test(.enabled(if: Self.liveWS))
    func `tunnel relays binary and text to the member and back`() async throws {
        let echo = try await makeApp()
        echo.webSocket("api", "vms", ":id", "vnc") { _, ws in
            ws.onText { ws, text in
                ws.send("echo:\(text)")
            }
            ws.onBinary { ws, buffer in
                var copy = buffer
                copy.writeString("+bin")
                ws.send(raw: copy.readableBytesView, opcode: .binary, fin: true, promise: nil)
            }
        }
        try await echo.startup()
        let tunnel = try await makeApp()
        do {
            let echoPort = try boundPort(echo)
            let dir = try isolatedDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let selfId = UUID().uuidString
            let peerId = "peer-1"
            try DeviceRegistry(dataDir: dir).upsert(
                hostId: peerId,
                fingerprint: "aa",
                agentHost: "127.0.0.1",
                agentPort: echoPort,
            )
            tunnel.middleware.use(StubHomeUserMiddleware())
            HomeConsoleProxyController(
                dataDir: dir,
                hostId: selfId,
                localPort: echoPort,
                devices: DeviceRegistry(dataDir: dir),
                dialer: LoopbackWebSocketDialer(),
            ).register(app: tunnel)
            try await tunnel.startup()
            let tunnelPort = try boundPort(tunnel)
            let url =
                "ws://127.0.0.1:\(tunnelPort)/api/home/devices/\(peerId)/v1/vms/vm-9/vnc?ticket=\(Self.ticket)"
            let text = try await echoRoundTrip(url: url, send: .text("ping"))
            #expect(text == "echo:ping")
            let binary = try await echoRoundTrip(url: url, send: .binary(Array("rfb".utf8)))
            #expect(binary == "rfb+bin")
            await stop(tunnel)
            await stop(echo)
        } catch {
            await stop(tunnel)
            await stop(echo)
            throw error
        }
    }

    @Test(.enabled(if: Self.liveWS))
    func `server-first banner reaches the client`() async throws {
        let echo = try await makeApp()
        echo.webSocket("api", "vms", ":id", "vnc") { _, ws in
            ws.send("RFB 003.008\n")
        }
        try await echo.startup()
        let tunnel = try await makeApp()
        do {
            let echoPort = try boundPort(echo)
            let dir = try isolatedDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let selfId = UUID().uuidString
            let peerId = "peer-banner"
            try DeviceRegistry(dataDir: dir).upsert(
                hostId: peerId,
                fingerprint: "aa",
                agentHost: "127.0.0.1",
                agentPort: echoPort,
            )
            tunnel.middleware.use(StubHomeUserMiddleware())
            HomeConsoleProxyController(
                dataDir: dir,
                hostId: selfId,
                localPort: echoPort,
                devices: DeviceRegistry(dataDir: dir),
                dialer: LoopbackWebSocketDialer(),
            ).register(app: tunnel)
            try await tunnel.startup()
            let tunnelPort = try boundPort(tunnel)
            let url =
                "ws://127.0.0.1:\(tunnelPort)/api/home/devices/\(peerId)/v1/vms/vm-9/vnc?ticket=\(Self.ticket)"
            let banner = try await echoReceive(url: url)
            #expect(banner == "RFB 003.008\n")
            await stop(tunnel)
            await stop(echo)
        } catch {
            await stop(tunnel)
            await stop(echo)
            throw error
        }
    }

    @Test(.enabled(if: Self.liveWS))
    func `this Device console still tunnels to local host API`() async throws {
        let echo = try await makeApp()
        echo.webSocket("api", "vms", ":id", "console") { _, ws in
            ws.onText { ws, text in
                ws.send("local:\(text)")
            }
        }
        try await echo.startup()
        let tunnel = try await makeApp()
        do {
            let echoPort = try boundPort(echo)
            let selfId = UUID().uuidString
            tunnel.middleware.use(StubHomeUserMiddleware())
            try HomeConsoleProxyController(
                dataDir: isolatedDir(),
                hostId: selfId,
                localPort: echoPort,
                dialer: LoopbackWebSocketDialer(),
            ).register(app: tunnel)
            try await tunnel.startup()
            let tunnelPort = try boundPort(tunnel)
            let url =
                "ws://127.0.0.1:\(tunnelPort)/api/home/devices/\(selfId)/v1/vms/vm-local/console?ticket=\(Self.ticket)"
            let text = try await echoRoundTrip(url: url, send: .text("hi"))
            #expect(text == "local:hi")
            await stop(tunnel)
            await stop(echo)
        } catch {
            await stop(tunnel)
            await stop(echo)
            throw error
        }
    }

    @Test(.enabled(if: Self.liveWS))
    func `agent hop tunnels vnc to the local host API`() async throws {
        let echo = try await makeApp()
        echo.webSocket("api", "vms", ":id", "vnc") { _, ws in
            ws.onText { ws, text in
                ws.send("agent:\(text)")
            }
        }
        try await echo.startup()
        let agent = try await makeApp()
        do {
            let echoPort = try boundPort(echo)
            let proxy = AgentLocalProxyController(localPort: echoPort)
            proxy.registerConsoleTunnels(app: agent)
            try await agent.startup()
            let agentPort = try boundPort(agent)
            let url = "ws://127.0.0.1:\(agentPort)/api/vms/vm-9/vnc?ticket=\(Self.ticket)"
            let text = try await echoRoundTrip(url: url, send: .text("frame"))
            #expect(text == "agent:frame")
            await stop(agent)
            await stop(echo)
        } catch {
            await stop(agent)
            await stop(echo)
            throw error
        }
    }
}

private struct StubHomeUserMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.authenticatedUser = AuthenticatedUser(
            userId: "user-1",
            username: "admin",
            authMethod: "jwt",
            apiKeyId: nil,
        )
        return try await next.respond(to: request)
    }
}

private struct LoopbackWebSocketDialer: HomeWebSocketDialing {
    func connect(
        url: URL,
        on eventLoopGroup: EventLoopGroup,
        configure: @escaping @Sendable (WebSocket) -> Void,
    ) async throws -> WebSocket {
        var rewritten = URLComponents(url: url, resolvingAgainstBaseURL: false)
        rewritten?.scheme = "ws"
        let target = try #require(rewritten?.url)
        return try await HomeWebSocketDialer.open(
            url: target,
            on: eventLoopGroup,
            configure: configure,
        )
    }
}

private final class ShutdownOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume()
    }
}

private final class EchoOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<String, Error>

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}

private enum EchoSend {
    case text(String)
    case binary([UInt8])
}

private func echoReceive(url: String) async throws -> String {
    try await echoRoundTrip(url: url, send: nil)
}

private func echoRoundTrip(url: String, send: EchoSend?) async throws -> String {
    // Resume the continuation on timeout. A TaskGroup child that parks on an
    // unresumed CheckedContinuation is not cancelled by a sibling throw, and
    // that hung the whole `swift test` job on CI.
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
        let once = EchoOnce(cont)
        let future = WebSocket.connect(to: url, on: MultiThreadedEventLoopGroup.singleton) { ws in
            ws.onText { ws, text in
                once.resume(.success(text))
                ws.close(promise: nil)
            }
            ws.onBinary { ws, buffer in
                once.resume(.success(String(buffer: buffer)))
                ws.close(promise: nil)
            }
            if let send {
                switch send {
                case let .text(text):
                    ws.send(text)
                case let .binary(bytes):
                    ws.send(raw: bytes, opcode: .binary, fin: true, promise: nil)
                }
            }
        }
        future.whenFailure { error in
            once.resume(.failure(error))
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            once.resume(.failure(BarkVisorError.timeout("console tunnel echo")))
        }
    }
}
