import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Host address inventory (PAS-63)")
struct HostAddressInventoryTests {
    @Test func `classifies LAN tailnet loopback and other`() {
        #expect(HostAddressClassifier.scope(of: "192.168.0.8") == .lan)
        #expect(HostAddressClassifier.scope(of: "10.1.2.3") == .lan)
        #expect(HostAddressClassifier.scope(of: "172.16.9.1") == .lan)
        #expect(HostAddressClassifier.scope(of: "fd12:3456:789a::1") == .lan)

        #expect(HostAddressClassifier.scope(of: "100.64.0.1") == .tailnet)
        #expect(HostAddressClassifier.scope(of: "100.127.255.254") == .tailnet)
        #expect(HostAddressClassifier.scope(of: "fd7a:115c:a1e0::1") == .tailnet)

        #expect(HostAddressClassifier.scope(of: "127.0.0.1") == .loopback)
        #expect(HostAddressClassifier.scope(of: "::1") == .loopback)

        #expect(HostAddressClassifier.scope(of: "8.8.8.8") == .other)
        #expect(HostAddressClassifier.scope(of: "169.254.1.1") == .other)
        #expect(HostAddressClassifier.scope(of: "100.100.100.200") == .other)
        #expect(HostAddressClassifier.scope(of: "fe80::1") == .other)
        #expect(HostAddressClassifier.scope(of: "fd00:ec2::254") == .other)
        #expect(HostAddressClassifier.scope(of: "box.example") == .other)
        #expect(HostAddressClassifier.scope(of: "") == .other)
    }

    @Test func `IPv4 mapped IPv6 follows the inner address`() {
        #expect(HostAddressClassifier.scope(of: "::ffff:192.168.0.8") == .lan)
        #expect(HostAddressClassifier.scope(of: "::ffff:100.64.0.1") == .tailnet)
        #expect(HostAddressClassifier.scope(of: "::ffff:127.0.0.1") == .loopback)
    }

    @Test func `collect keeps LAN and tailnet and drops loopback`() {
        let ifaces = [
            HostInterfaceInfo(name: "lo", ipAddress: "127.0.0.1"),
            HostInterfaceInfo(name: "en0", ipAddress: "192.168.0.8"),
            HostInterfaceInfo(name: "en0", ipAddress: "fd12:3456:789a::8"),
            HostInterfaceInfo(name: "tailscale0", ipAddress: "100.64.12.34"),
            HostInterfaceInfo(name: "tailscale0", ipAddress: "fd7a:115c:a1e0::34"),
            HostInterfaceInfo(name: "en0", ipAddress: "8.8.8.8"),
        ]
        let addrs = HostAddressClassifier.collect(from: ifaces, tailnet: nil)
        #expect(addrs.lan == ["192.168.0.8", "fd12:3456:789a::8"])
        #expect(addrs.tailnet == ["100.64.12.34", "fd7a:115c:a1e0::34"])
        #expect(!addrs.lan.contains("127.0.0.1"))
        #expect(!addrs.tailnet.contains("8.8.8.8"))
    }

    @Test func `collect merges Tailscale probe IP without duplicating`() {
        let ifaces = [HostInterfaceInfo(name: "en0", ipAddress: "10.0.0.4")]
        let tailnet = TailnetInfo(available: true, ip: "100.64.9.9", dnsName: "box.ts.net")
        let addrs = HostAddressClassifier.collect(from: ifaces, tailnet: tailnet)
        #expect(addrs.lan == ["10.0.0.4"])
        #expect(addrs.tailnet == ["100.64.9.9"])

        let already = [
            HostInterfaceInfo(name: "en0", ipAddress: "10.0.0.4"),
            HostInterfaceInfo(name: "tailscale0", ipAddress: "100.64.9.9"),
        ]
        let merged = HostAddressClassifier.collect(from: already, tailnet: tailnet)
        #expect(merged.tailnet == ["100.64.9.9"])

        let down = TailnetInfo(available: false, ip: "100.64.9.9", dnsName: "stale.ts.net")
        let stale = HostAddressClassifier.collect(from: ifaces, tailnet: down)
        #expect(stale.tailnet.isEmpty)
    }
}
