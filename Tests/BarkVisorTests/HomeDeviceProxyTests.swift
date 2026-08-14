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
}

private struct FailingProxyClient: HomeDeviceProxyClient {
    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        throw HomeDeviceProxyError.unreachable("peer down")
    }
}
