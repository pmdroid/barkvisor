import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Device URL (PAS-89)")
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
        #expect(try RemoteAccessSettings.parseAdvertiseHost("192.168.1.9:8080") == "192.168.1.9")
        #expect(try RemoteAccessSettings.parseAdvertiseHost("http://box.ts.net:7777") == "box.ts.net")
        #expect(try RemoteAccessSettings.parseAdvertiseHost("box.ts.net:7777") == "box.ts.net")
        #expect(
            try RemoteAccessSettings.parseAdvertiseHost("http://box.ts.net/ignored") == "box.ts.net",
        )
        #expect(
            try RemoteAccessSettings.parseAdvertiseHost("fd12:3456:789a::1") == "fd12:3456:789a::1",
        )
        #expect(
            try RemoteAccessSettings.parseAdvertiseHost("[fd12:3456:789a::1]:7777")
                == "fd12:3456:789a::1",
        )
        #expect(
            try RemoteAccessSettings.parseAdvertiseHost("http://[fd12:3456:789a::1]:7777")
                == "fd12:3456:789a::1",
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

    @Test func `settings persist Device URL host`() throws {
        let (pool, dir) = try isolatedDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try pool.read { try RemoteAccessSettings.load(from: $0) }
        #expect(empty.deviceUrl == nil)
        let saved = try pool.write { db in
            try RemoteAccessSettings.save(
                deviceUrl: "http://100.64.1.2:7777",
                updateDeviceUrl: true,
                db: db,
            )
        }
        #expect(saved.deviceUrl == "100.64.1.2")
        let cleared = try pool.write { db in
            try RemoteAccessSettings.save(
                deviceUrl: "  ",
                updateDeviceUrl: true,
                db: db,
            )
        }
        #expect(cleared.deviceUrl == nil)
        #expect(throws: BarkVisorError.self) {
            try pool.write { db in
                _ = try RemoteAccessSettings.save(
                    deviceUrl: "8.8.8.8",
                    updateDeviceUrl: true,
                    db: db,
                )
            }
        }
        #expect(try pool.read { try RemoteAccessSettings.load(from: $0).deviceUrl == nil })
        let custom = try pool.write { db in
            try RemoteAccessSettings.save(
                deviceUrl: "https://studio.home:443",
                updateDeviceUrl: true,
                db: db,
            )
        }
        #expect(custom.deviceUrl == "studio.home")
        #expect(try pool.read { try RemoteAccessSettings.load(from: $0).deviceUrl == "studio.home" })
        let body = Data(#"{"deviceUrl":"https://nas.lan"}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteAccessPutBody.self, from: body)
        #expect(decoded.deviceUrl == "https://nas.lan")
        let parsed = try RemoteAccessSettings.parseAdvertiseHost(decoded.deviceUrl)
        let put = try pool.write { db in
            try RemoteAccessSettings.save(
                deviceUrl: parsed,
                updateDeviceUrl: true,
                db: db,
            )
        }
        #expect(put.deviceUrl == "nas.lan")
        #expect(try pool.read { try RemoteAccessSettings.load(from: $0).deviceUrl == "nas.lan" })
    }

    @Test func `magicdns Device URL is https without a port`() {
        #expect(RemoteAccessSettings.isMagicDNSHost("box.tailnet.ts.net"))
        #expect(RemoteAccessSettings.isMagicDNSHost("box.tailscale.net"))
        #expect(!RemoteAccessSettings.isMagicDNSHost("192.168.0.4"))
        #expect(
            RemoteAccessSettings.formatDeviceURL("box.tailnet.ts.net")
                == "https://box.tailnet.ts.net",
        )
        #expect(
            RemoteAccessSettings.formatDeviceURL("https://box.tailnet.ts.net:443")
                == "https://box.tailnet.ts.net",
        )
        #expect(RemoteAccessSettings.formatDeviceURL("192.168.0.4") == "http://192.168.0.4:7777")
        #expect(!RemoteAccessSettings.formatDeviceURL("box.tailnet.ts.net").contains(":443"))
        #expect(!RemoteAccessSettings.formatDeviceURL("box.tailnet.ts.net").contains(":7777"))
        let up = TailnetInfo(available: true, ip: "100.64.1.2", dnsName: "box.tailnet.ts.net")
        #expect(RemoteAccessSettings.magicDNSHost(tailnet: up) == "box.tailnet.ts.net")
        let down = TailnetInfo(available: false, ip: nil, dnsName: "stale.tailnet.ts.net")
        #expect(RemoteAccessSettings.magicDNSHost(tailnet: down) == nil)
    }

    @Test func `advertised hosts prefer Device URL then tailnet then LAN`() {
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
        #expect(
            PairingAddresses.advertisedHosts(
                from: ifaces, tailnet: tailnet, advertiseUrl: nil, hostname: "studio.local",
            ) == [
                "box.tailnet.ts.net",
                "100.64.12.34",
                "studio.local",
                "192.168.0.4",
            ],
        )
        let down = TailnetInfo(
            available: false, ip: nil, dnsName: "stale.tailnet.ts.net",
        )
        #expect(
            PairingAddresses.advertisedHosts(from: ifaces, tailnet: down, advertiseUrl: nil)
                == ["192.168.0.4", "100.64.12.34"],
        )
    }

    @Test func `inventory snapshot uses last-known tailnet without probing`() throws {
        TailscaleProbe.resetCache()
        TailscaleProbe.seedCache(
            TailnetInfo(available: true, ip: "100.64.9.9", dnsName: "box.ts.net"),
            now: Date().addingTimeInterval(-60),
        )
        #expect(TailscaleProbe.lastKnown()?.ip == "100.64.9.9")
        TailscaleProbe.seedCache(
            TailnetInfo(available: true, ip: "100.64.9.9", dnsName: "box.ts.net"),
        )
        let inv = HostInventoryService.snapshot(
            hostId: "11111111-1111-1111-1111-111111111111",
        )
        #expect(inv.networking.tailnet?.ip == "100.64.9.9")
        #expect(inv.networking.tailnet?.dnsName == "box.ts.net")
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(HostInventory.self, from: data)
        #expect(decoded.networking.tailnet == inv.networking.tailnet)
    }
}

private struct RemoteAccessPutBody: Decodable {
    var deviceUrl: String?
}
