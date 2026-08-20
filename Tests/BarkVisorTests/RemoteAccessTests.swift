import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Remote access (PAS-89)")
struct RemoteAccessTests {
    private func isolatedDB() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return (pool, dir)
    }

    @Test func `tailscale ip -4 parser accepts CGNAT and rejects junk`() {
        #expect(TailscaleProbe.parseIPv4Output("100.64.1.2\n") == "100.64.1.2")
        #expect(TailscaleProbe.parseIPv4Output("  100.127.0.1  ") == "100.127.0.1")
        #expect(TailscaleProbe.parseIPv4Output("100.100.100.200") == nil)
        #expect(TailscaleProbe.parseIPv4Output("8.8.8.8") == nil)
        #expect(TailscaleProbe.parseIPv4Output("not-an-ip") == nil)
        #expect(TailscaleProbe.parseIPv4Output("") == nil)
    }

    @Test func `tailscale status JSON yields MagicDNS and IPv4`() {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "box.tailnet.ts.net.",
            "TailscaleIPs": ["100.64.9.9", "fd7a:115c:a1e0::1"]
          }
        }
        """
        let parsed = TailscaleProbe.parseStatusJSON(json)
        #expect(parsed.ip == "100.64.9.9")
        #expect(parsed.dnsName == "box.tailnet.ts.net")
    }

    @Test func `detect uses injected runner and does not require a binary`() {
        let runner = TailscaleProbe.Runner(executablePath: "/tmp/fake-tailscale") { _, args in
            if args == ["ip", "-4"] {
                return CommandResult(
                    exitCode: 0,
                    stdout: Data("100.64.8.8\n".utf8),
                    stderr: Data(),
                )
            }
            if args == ["status", "--json"] {
                let json = #"{"Self":{"DNSName":"n.ts.net.","TailscaleIPs":["100.64.8.8"]}}"#
                return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
            }
            return CommandResult(exitCode: 1, stdout: Data(), stderr: Data())
        }
        let info = TailscaleProbe.detect(runner: runner, useCache: false)
        #expect(info.available)
        #expect(info.ip == "100.64.8.8")
        #expect(info.dnsName == "n.ts.net")
    }

    @Test func `detect is unavailable when the command fails`() {
        let runner = TailscaleProbe.Runner(executablePath: "/tmp/missing-tailscale") { _, _ in
            CommandResult(exitCode: 1, stdout: Data(), stderr: Data("not logged in".utf8))
        }
        let info = TailscaleProbe.detect(runner: runner, useCache: false)
        #expect(!info.available)
        #expect(info.ip == nil)
    }

    @Test func `wireguard iface names are wgN only`() {
        #expect(WireGuardProbe.isWireGuardInterfaceName("wg0"))
        #expect(WireGuardProbe.isWireGuardInterfaceName("wg12"))
        #expect(!WireGuardProbe.isWireGuardInterfaceName("wlp2s0"))
        #expect(!WireGuardProbe.isWireGuardInterfaceName("tailscale0"))
        #expect(
            WireGuardProbe.detect(interfaces: [HostInterfaceInfo(name: "wg0", ipAddress: "10.0.0.2")])
                .configured,
        )
        #expect(
            !WireGuardProbe.detect(interfaces: [HostInterfaceInfo(name: "en0", ipAddress: "192.168.0.4")])
                .configured,
        )
    }

    @Test func `advertise host strips scheme and port`() throws {
        #expect(try RemoteAccessSettings.parseAdvertiseHost("  ") == nil)
        #expect(try RemoteAccessSettings.parseAdvertiseHost("100.64.1.2") == "100.64.1.2")
        #expect(try RemoteAccessSettings.parseAdvertiseHost("http://box.ts.net:7777") == "box.ts.net")
        #expect(try RemoteAccessSettings.parseAdvertiseHost("box.ts.net:7777") == "box.ts.net")
        #expect(
            try RemoteAccessSettings.parseAdvertiseHost("http://box.ts.net/ignored") == "box.ts.net",
        )
        #expect(throws: BarkVisorError.self) {
            try RemoteAccessSettings.parseAdvertiseHost("8.8.8.8")
        }
        #expect(throws: BarkVisorError.self) {
            try RemoteAccessSettings.parseAdvertiseHost("evil.example/path")
        }
        #expect(throws: BarkVisorError.self) {
            try RemoteAccessSettings.parseAdvertiseHost("localhost")
        }
    }

    @Test func `settings persist require flag and advertise host`() throws {
        let (pool, dir) = try isolatedDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try pool.read { try RemoteAccessSettings.load(from: $0) }
        #expect(!empty.requireTailnetForRemote)
        #expect(empty.advertiseUrl == nil)
        let saved = try pool.write { db in
            try RemoteAccessSettings.save(
                requireTailnetForRemote: true,
                advertiseUrl: "http://100.64.1.2:7777",
                updateAdvertiseUrl: true,
                db: db,
            )
        }
        #expect(saved.requireTailnetForRemote)
        #expect(saved.advertiseUrl == "100.64.1.2")
        let cleared = try pool.write { db in
            try RemoteAccessSettings.save(
                advertiseUrl: "  ",
                updateAdvertiseUrl: true,
                db: db,
            )
        }
        #expect(cleared.requireTailnetForRemote)
        #expect(cleared.advertiseUrl == nil)
    }

    @Test func `peer policy allows LAN tailnet and loopback, not public`() {
        #expect(RemoteAccessSettings.allowsPeer("127.0.0.1"))
        #expect(RemoteAccessSettings.allowsPeer("::1"))
        #expect(RemoteAccessSettings.allowsPeer("192.168.1.9"))
        #expect(RemoteAccessSettings.allowsPeer("10.0.0.2"))
        #expect(RemoteAccessSettings.allowsPeer("100.64.1.2"))
        #expect(RemoteAccessSettings.allowsPeer("fd12:3456:789a::1"))
        #expect(!RemoteAccessSettings.allowsPeer("8.8.8.8"))
        #expect(!RemoteAccessSettings.allowsPeer("100.100.100.200"))
        #expect(!RemoteAccessSettings.allowsPeer(nil))
        #expect(!RemoteAccessSettings.allowsPeer(""))
        #expect(!RemoteAccessSettings.allowsPeer("box.ts.net"))
        #expect(!RemoteAccessSettings.allowsPeer("not-an-ip"))
    }

    @Test func `advertised hosts prefer advertise URL then tailnet then LAN`() {
        let ifaces = [
            HostInterfaceInfo(name: "en0", ipAddress: "192.168.0.4"),
            HostInterfaceInfo(name: "tun0", ipAddress: "100.64.12.34"),
        ]
        let tailnet = TailnetInfo(
            available: true, ip: "100.64.12.34", dnsName: "box.tailnet.ts.net",
        )
        #expect(
            PairingAddresses.advertisedHosts(
                from: ifaces, tailnet: tailnet, advertiseUrl: "home.ts.net",
            ) == [
                "home.ts.net",
                "box.tailnet.ts.net",
                "100.64.12.34",
                "192.168.0.4",
            ],
        )
        #expect(
            PairingAddresses.advertisedHosts(from: ifaces, tailnet: tailnet, advertiseUrl: nil)
                .first == "box.tailnet.ts.net",
        )
        let down = TailnetInfo(
            available: false, ip: nil, dnsName: "stale.tailnet.ts.net",
        )
        #expect(
            PairingAddresses.advertisedHosts(from: ifaces, tailnet: down, advertiseUrl: nil)
                == ["192.168.0.4", "100.64.12.34"],
        )
    }

    @Test func `gate exempts health contract and capabilities only`() {
        #expect(RemoteAccessGate.isExempt("/"))
        #expect(RemoteAccessGate.isExempt("/index.html"))
        #expect(RemoteAccessGate.isExempt("/api/health"))
        #expect(RemoteAccessGate.isExempt("/api/openapi.yaml"))
        #expect(RemoteAccessGate.isExempt("/api/contract"))
        #expect(RemoteAccessGate.isExempt("/api/workloadspec.schema.json"))
        #expect(RemoteAccessGate.isExempt("/api/system/capabilities"))
        #expect(!RemoteAccessGate.isExempt("/api/auth/login"))
        #expect(!RemoteAccessGate.isExempt("/api/system/remote-access"))
        #expect(!RemoteAccessGate.isExempt("/api/vms/1/console"))
        #expect(!RemoteAccessGate.isExempt("/api/home/devices/x/v1/vms/y/vnc"))
        #expect(!RemoteAccessGate.isExempt("/api/auth/ws-ticket"))
    }

    @Test func `inventory snapshot includes tailnet field`() throws {
        let inv = HostInventoryService.snapshot(
            hostId: "11111111-1111-1111-1111-111111111111",
        )
        let data = try JSONEncoder().encode(inv)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let networking = try #require(object["networking"] as? [String: Any])
        let tailnet = try #require(networking["tailnet"] as? [String: Any])
        #expect(tailnet["available"] is Bool)
        let decoded = try JSONDecoder().decode(HostInventory.self, from: data)
        #expect(decoded.networking.tailnet == inv.networking.tailnet)
    }
}
