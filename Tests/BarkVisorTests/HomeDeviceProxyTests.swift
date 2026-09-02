#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import AsyncHTTPClient
import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home device proxy (PAS-34)")
struct HomeDeviceProxyTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "home-proxy-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `member path rewrite rejects traversal and nested home`() throws {
        #expect(try HomeDeviceProxy.memberAPIPath(components: ["vms"]) == "/api/vms")
        #expect(
            try HomeDeviceProxy.memberAPIPath(components: ["agent", "inventory"])
                == "/api/agent/inventory",
        )
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberAPIPath(components: [])
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberAPIPath(components: ["..", "etc"])
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberAPIPath(components: ["home", "devices"])
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberAPIPath(components: ["setup", "admin"])
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberAPIPath(components: ["pairing", "join"])
        }
        #expect(
            try HomeDeviceProxy.memberAPIPath(components: ["pairing", "redeem"])
                == "/api/pairing/redeem",
        )
    }

    @Test func `agent proxy rejects setup and pairing join`() throws {
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/setup"))
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/setup/admin"))
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/setup/status"))
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/pairing/join"))
        #expect(HomeDeviceProxy.isConsoleLocalOnly("/api/pairing/join/extra"))
        #expect(!HomeDeviceProxy.isConsoleLocalOnly("/api/pairing/redeem"))
        #expect(!HomeDeviceProxy.isConsoleLocalOnly("/api/vms"))
        #expect(!HomeDeviceProxy.isConsoleLocalOnly("/api/agent/whoami"))
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.rejectConsoleLocalOnly("/api/setup/admin")
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.rejectConsoleLocalOnly("/api/pairing/join")
        }
        try HomeDeviceProxy.rejectConsoleLocalOnly("/api/vms")
        try HomeDeviceProxy.rejectConsoleLocalOnly("/api/pairing/redeem")
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberURL(
                host: "192.168.1.9",
                port: 7_778,
                path: "/api/setup/status",
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.localURL(port: 7_777, path: "/api/pairing/join")
        }
    }

    @Test func `cancellable stream cancels producer when consumer stops`() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false
            func mark() {
                lock.lock()
                cancelled = true
                lock.unlock()
            }
            func value() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }
        }
        let flag = Flag()
        try await withThrowingTaskGroup(of: Void.self) { group in
            let stream = CancellableAsyncThrowingStream.make { continuation in
                continuation.yield(Data([1]))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                flag.mark()
                continuation.finish()
            }
            group.addTask {
                for try await _ in stream {
                    break
                }
            }
            try await group.next()
            group.cancelAll()
        }
        var seen = false
        for _ in 0 ..< 200 {
            if flag.value() {
                seen = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(seen)
    }

    @Test func `member URL allows loopback and RFC1918 and rejects public`() throws {
        let lan = try HomeDeviceProxy.memberURL(
            host: "192.168.1.9",
            port: 7_778,
            path: "/api/agent/whoami",
        )
        #expect(lan.host == "192.168.1.9")
        #expect(lan.port == 7_778)
        #expect(lan.scheme == "https")

        let loop = try HomeDeviceProxy.localURL(port: 7_777, path: "/api/vms")
        #expect(loop.host == "127.0.0.1")
        #expect(loop.scheme == "http")

        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberURL(host: "8.8.8.8", port: 7_778, path: "/api/vms")
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberURL(
                host: "evil.example.com",
                port: 7_778,
                path: "/api/vms",
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberURL(
                host: "no-such-host.invalid",
                port: 7_778,
                path: "/api/vms",
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.memberURL(
                host: "192.168.1.9",
                port: 7_778,
                path: "/api/home/devices",
            )
        }
    }

    @Test func `agent proxy path decodes and rejects traversal before guards`() throws {
        #expect(try HomeDeviceProxy.normalizedAPIPath("/api/vms") == "/api/vms")
        #expect(try HomeDeviceProxy.normalizedAPIPath("/api/agent/whoami") == "/api/agent/whoami")
        #expect(try HomeDeviceProxy.normalizedAPIPath("/api/%73etup") == "/api/setup")
        #expect(try HomeDeviceProxy.normalizedAPIPath("/api/pairing/%6Aoin") == "/api/pairing/join")
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.normalizedAPIPath("/api/x/../pairing/join")
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.normalizedAPIPath("/api/%2e%2e/setup")
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.normalizedAPIPath("/api/foo%2Fbar")
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.normalizedAPIPath("/api/.")
        }
        try HomeDeviceProxy.rejectConsoleLocalOnly(HomeDeviceProxy.normalizedAPIPath("/api/vms"))
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.rejectConsoleLocalOnly(
                HomeDeviceProxy.normalizedAPIPath("/api/%73etup/admin"),
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.rejectConsoleLocalOnly(
                HomeDeviceProxy.normalizedAPIPath("/api/pairing/%6Aoin"),
            )
        }
    }

    @Test func `classify maps HTTPClientError connect cancel TLS and error 1`() {
        #expect(HomeDeviceProxyError.classify(HTTPClientError.connectTimeout) == .connectTimeout)
        #expect(HomeDeviceProxyError.classify(HTTPClientError.cancelled) == .cancelled)
        #expect(HomeDeviceProxyError.classify(HTTPClientError.tlsHandshakeTimeout) == .tlsFailure)
        #expect(HomeDeviceProxyError.classify(HTTPClientError.deadlineExceeded) == .connectTimeout)
        #expect(HomeDeviceProxyError.classify(CancellationError()) == .cancelled)

        let error1 = NSError(
            domain: "AsyncHTTPClient.HTTPClientError",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The operation could not be completed. (AsyncHTTPClient.HTTPClientError error 1.)",
            ],
        )
        #expect(HomeDeviceProxyError.classify(error1) == .connectTimeout)
        #expect(HomeDeviceProxyError.connectTimeout.reachability == "connectTimeout")
        #expect(HomeDeviceProxyError.cancelled.reachability == "cancelled")
        #expect(HomeDeviceProxyError.tlsFailure.reachability == "tlsFailure")
        #expect(HomeDeviceProxyError.memberHTTP(503).reachability == "memberHTTP")
        #expect(HomeDeviceProxyError.responseTooLarge.reachability == "responseTooLarge")
        #expect(HomeDeviceProxyError.healthUnreachable.reachability == "unreachable")
        #expect(
            HomeDeviceProxyError.connectTimeout.errorDescription
                == "Home cannot hop to the Device: connection timed out",
        )
        #expect(
            HomeDeviceProxyError.memberHTTP(503).ollamaHopDescription
                == "Ollama is down on the Device (HTTP 503)",
        )
        #expect(
            HomeDeviceProxyError.memberHTTP(404).ollamaHopDescription
                == "Device returned HTTP 404",
        )
        #expect(
            HomeDeviceProxyError.memberHTTP(401).ollamaHopDescription
                == "Device returned HTTP 401",
        )
        #expect(
            HomeDeviceProxyError.memberHTTP(400).ollamaHopDescription
                == "Device returned HTTP 400",
        )
        #expect(!HomeDeviceProxyError.memberHTTP(404).ollamaHopDescription.contains("Ollama is down"))
        #expect(HomeDeviceProxyError.healthUnreachable.errorDescription == "Device is unreachable")
        #expect(
            HomeDeviceProxyError.connectTimeout.localizedDescription
                != "Device is unreachable: The operation could not be completed. (AsyncHTTPClient.HTTPClientError error 1.)",
        )
    }

    @Test func `proxy client 502 does not require sqlite`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        try DeviceRegistry(dataDir: dir).upsert(
            hostId: "member-1",
            fingerprint: "aa",
            agentHost: "10.0.0.9",
            agentPort: 7_778,
        )
        let listed = HomeDeviceDirectory.list(dataDir: dir, hostId: hostId)
        #expect(listed.devices.contains { $0.hostId == "member-1" })
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("db.sqlite").path))

        let failing = FailingProxyClient()
        let unreachable = try #require(URL(string: "https://10.0.0.9:7778/api/agent/whoami"))
        await #expect(throws: HomeDeviceProxyError.self) {
            try await failing.send(
                HomeDeviceProxyRequest(method: "GET", url: unreachable),
            )
        }
    }

    @Test func `mtls client hop timeout defaults to two seconds`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: UUID().uuidString)
        let client = AgentMTLSClient(material: material)
        #expect(client.timeoutSeconds == HomeDeviceProxy.hopTimeoutSeconds)
        #expect(client.timeoutSeconds == 2)
        #expect(client.timeoutSeconds != 10)
    }

    @Test func `mtls client reaches agent whoami`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let pins = PeerPinStore(dataDir: dir)
        let server = AgentTLSServer(
            material: material,
            pins: pins,
            hostname: "127.0.0.1",
            port: 0,
        )
        try await server.start()
        do {
            let port = try #require(server.boundPort)
            let client = AgentMTLSClient(material: material)
            let url = try HomeDeviceProxy.memberURL(
                host: "127.0.0.1",
                port: port,
                path: "/api/agent/whoami",
            )
            let response = try await client.send(
                HomeDeviceProxyRequest(method: "GET", url: url),
            )
            #expect((200 ... 299).contains(response.status))
            let body = try JSONDecoder().decode(AgentPeerIdentity.self, from: response.body)
            #expect(body.hostId == hostId)
            #expect(body.trust == "home-ca")
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `local host proxy caps response body`() async throws {
        let oversized = try LocalStaticHTTPServer(body: Data(repeating: 0x61, count: 32))
        let within = try LocalStaticHTTPServer(body: Data("ok".utf8))
        defer {
            oversized.stop()
            within.stop()
        }
        let bigURL = try #require(URL(string: "http://127.0.0.1:\(oversized.port)/"))
        let smallURL = try #require(URL(string: "http://127.0.0.1:\(within.port)/"))
        let client = LocalHostProxyClient(maxBodyBytes: 16)
        await #expect(throws: HomeDeviceProxyError.responseTooLarge) {
            try await client.send(HomeDeviceProxyRequest(method: "GET", url: bigURL))
        }
        let response = try await client.send(HomeDeviceProxyRequest(method: "GET", url: smallURL))
        #expect(response.status == 200)
        #expect(response.body == Data("ok".utf8))
    }

    @Test func `console path is vnc or serial and not a nested home hop`() throws {
        #expect(HomeDeviceProxy.consoleKind(components: ["vms", "vm-1", "vnc"]) == .vnc)
        #expect(HomeDeviceProxy.consoleKind(components: ["vms", "vm-1", "console"]) == .console)
        #expect(HomeDeviceProxy.consoleKind(components: ["vms", "vm-1", "start"]) == nil)
        #expect(try HomeDeviceProxy.consoleKind(apiPath: "/api/vms/vm-1/vnc") == .vnc)
        #expect(try HomeDeviceProxy.consoleKind(apiPath: "/api/vms/vm-1/console") == .console)
        #expect(try HomeDeviceProxy.consoleKind(apiPath: "/api/auth/ws-ticket") == nil)
        #expect(
            try HomeDeviceProxy.memberAPIPath(components: ["vms", "vm-1", "vnc"])
                == "/api/vms/vm-1/vnc",
        )
        #expect(
            try HomeDeviceProxy.memberAPIPath(components: ["auth", "ws-ticket"])
                == "/api/auth/ws-ticket",
        )
    }

    @Test func `console target URL is ws on this Device and wss on a member`() throws {
        let local = try HomeDeviceProxy.consoleTargetURL(
            HomeConsoleTarget(
                isSelf: true,
                localPort: 7_777,
                agentHost: nil,
                agentPort: 7_778,
                vmID: "vm-1",
                kind: .vnc,
                query: "ticket=abc",
            ),
        )
        #expect(local.scheme == "ws")
        #expect(local.host == "127.0.0.1")
        #expect(local.port == 7_777)
        #expect(local.path == "/api/vms/vm-1/vnc")
        #expect(local.query == "ticket=abc")

        let member = try HomeDeviceProxy.consoleTargetURL(
            HomeConsoleTarget(
                isSelf: false,
                localPort: 7_777,
                agentHost: "10.0.0.9",
                agentPort: 7_778,
                vmID: "vm-1",
                kind: .console,
                query: "ticket=abc&session=home&token=novnc",
            ),
        )
        #expect(member.scheme == "wss")
        #expect(member.host == "10.0.0.9")
        #expect(member.port == 7_778)
        #expect(member.path == "/api/vms/vm-1/console")
        #expect(member.query == "ticket=abc")

        let rewritten = try HomeDeviceProxy.consoleTargetURL(
            HomeConsoleTarget(
                isSelf: true,
                localPort: 7_777,
                agentHost: nil,
                agentPort: 7_778,
                vmID: "vm-1",
                kind: .vnc,
                query: "token=device-ticket&session=home",
            ),
        )
        #expect(rewritten.query == "ticket=device-ticket")

        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.consoleTargetURL(
                HomeConsoleTarget(
                    isSelf: false,
                    localPort: 7_777,
                    agentHost: nil,
                    agentPort: 7_778,
                    vmID: "vm-1",
                    kind: .vnc,
                    query: "ticket=abc",
                ),
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HomeDeviceProxy.consoleTargetURL(
                HomeConsoleTarget(
                    isSelf: false,
                    localPort: 7_777,
                    agentHost: "8.8.8.8",
                    agentPort: 7_778,
                    vmID: "vm-1",
                    kind: .vnc,
                    query: "ticket=abc",
                ),
            )
        }
    }
}

private struct FailingProxyClient: HomeDeviceProxyClient {
    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        throw HomeDeviceProxyError.unreachable("peer down")
    }
}

/// Serves a fixed HTTP body on loopback so body-cap tests do not bind TLS.
private final class LocalStaticHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init(body: Data) throws {
        let sock = socket(AF_INET, PlatformSocket.stream, 0)
        guard sock >= 0 else { throw BarkVisorError.badRequest("socket") }
        var yes: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0, listen(sock, 8) == 0 else {
            close(sock)
            throw BarkVisorError.badRequest("bind")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRC = withUnsafeMutablePointer(to: &got) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard nameRC == 0 else {
            close(sock)
            throw BarkVisorError.badRequest("getsockname")
        }
        self.fd = sock
        self.port = Int(UInt16(bigEndian: got.sin_port))
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [fd = sock, body] in
            ready.signal()
            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(fd, $0, &clientLen)
                    }
                }
                if client < 0 { break }
                var buf = [UInt8](repeating: 0, count: 1_024)
                _ = read(client, &buf, buf.count)
                var payload = Data(
                    "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        .utf8,
                )
                payload.append(body)
                payload.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = write(client, base, raw.count)
                }
                close(client)
            }
        }
        ready.wait()
    }

    func stop() {
        close(fd)
    }
}
