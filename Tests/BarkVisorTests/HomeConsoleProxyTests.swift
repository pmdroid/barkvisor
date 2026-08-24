import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import NIOCore
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home console WebSocket tunnel (PAS-200)", .serialized)
struct HomeConsoleProxyTests {
    private static let ticket = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

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
}

private struct StubHomeUserMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.authenticatedUser = AuthenticatedUser(
            userId: "user-1",
            username: "admin",
            authMethod: "jwt",
            apiKeyId: nil,
            role: UserRole.admin.rawValue,
        )
        return try await next.respond(to: request)
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
