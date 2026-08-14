#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
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
                host: "192.168.1.9",
                port: 7_778,
                path: "/api/home/devices",
            )
        }
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
