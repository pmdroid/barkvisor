import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Pairing payload (PAS-45)")
struct PairingPayloadTests {
    @Test func `short code normalizes and hashes stably`() {
        let code = PairingCode.generate(bytes: Array(repeating: 3, count: 8))
        #expect(PairingCode.isValid(code))
        #expect(code.contains("-"))
        #expect(PairingCode.normalize(" abcd-efgh ") == "ABCDEFGH")
        #expect(PairingCode.hash("abcd-efgh") == PairingCode.hash("ABCDEFGH"))
        #expect(PairingCode.hashesEqual(PairingCode.hash("AA"), PairingCode.hash("aa")))
        #expect(!PairingCode.isValid("SHORT"))
        #expect(!PairingCode.isValid("IIIIIIII"))
    }

    @Test func `qr payload round trips host port hostId and fingerprint`() throws {
        let payload = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.168.0.10",
            port: 7_777,
            agentPort: 7_778,
            hostId: "host-a",
            fingerprint: "ABCdef",
        )
        let parsed = try PairingPayload.parse(payload.uri)
        #expect(parsed.code == "ABCD-EFGH")
        #expect(parsed.host == "192.168.0.10")
        #expect(parsed.port == 7_777)
        #expect(parsed.agentPort == 7_778)
        #expect(parsed.hostId == "host-a")
        #expect(parsed.fingerprint == "abcdef")
        #expect(throws: PairingError.self) {
            try PairingPayload.parse("https://evil.example/pair")
        }
        #expect(PairingPayload.sanitizeHost("http://x") == nil)
        #expect(PairingPayload.sanitizeHost("127.0.0.1") == nil)
        #expect(PairingPayload.sanitizeHost("localhost") == nil)
        #expect(PairingPayload.sanitizeHost("169.254.169.254") == nil)
        #expect(PairingPayload.sanitizeHost("metadata.google.internal") == nil)
        #expect(PairingPayload.sanitizeHost("192.168.1.10") == "192.168.1.10")
        #expect(PairingPayload.sanitizeProxyHost("127.0.0.1") == "127.0.0.1")
        #expect(PairingPayload.sanitizeProxyHost("localhost") == "localhost")
        #expect(PairingPayload.sanitizeProxyHost("192.168.1.10") == "192.168.1.10")
        #expect(PairingPayload.sanitizeProxyHost("8.8.8.8") == nil)
        #expect(PairingPayload.sanitizeProxyHost("169.254.169.254") == nil)
        #expect(PairingPayload.sanitizeProxyHost("evil.example.com") == nil)
        #expect(PairingPayload.sanitizeProxyHost("no-such-host.invalid") == nil)
        #expect(PairingPayload.sanitizeHost("10.0.0.5") == "10.0.0.5")
        #expect(PairingPayload.sanitizeHost("127.1") == nil)
        #expect(PairingPayload.sanitizeHost("127.0.1") == nil)
        #expect(PairingPayload.sanitizeHost("2130706433") == nil)
        #expect(PairingPayload.sanitizeHost("0177.0.0.1") == nil)
        #expect(PairingPayload.sanitizeHost("0x7f.0.0.1") == nil)
        #expect(PairingPayload.sanitizeHost("0x7f000001") == nil)
        #expect(PairingPayload.isBlockedJoinHost("127.1"))
        #expect(PairingPayload.isBlockedJoinHost("2130706433"))
        #expect(PairingPayload.isBlockedJoinHost("0177.0.0.1"))
        #expect(PairingPayload.isBlockedJoinHost("0x7f.1"))
        #expect(PairingPayload.isBlockedJoinHost("::ffff:127.0.0.1"))
        #expect(PairingPayload.isBlockedJoinHost("::ffff:7f00:1"))
        #expect(!PairingPayload.isBlockedJoinHost("192.168.1.10"))
        #expect(PairingPayload.hostResolvesToBlockedAddress("127.0.0.1"))
        #expect(!PairingPayload.hostResolvesToBlockedAddress("192.168.1.10"))
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "127.0.0.1", port: 7_777)
        }
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "127.1", port: 7_777)
        }
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "2130706433", port: 7_777)
        }
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "169.254.169.254", port: 80)
        }
        let lan = try PairingPayload.redeemURL(host: "192.168.1.10", port: 7_777)
        #expect(lan.host == "192.168.1.10")
        #expect(lan.path == "/api/pairing/redeem")
        let contract = try PairingPayload.contractURL(host: "192.168.1.10", port: 7_777)
        #expect(contract.host == "192.168.1.10")
        #expect(contract.path == "/api/contract")
        #expect(throws: PairingError.self) {
            try PairingPayload.contractURL(host: "127.0.0.1", port: 7_777)
        }
        #expect(throws: PairingError.self) {
            try PairingPayload.parse(
                PairingPayload(
                    code: "ABCD-EFGH",
                    host: "127.0.0.1",
                    port: 7_777,
                    hostId: "host-a",
                    fingerprint: "abcd",
                ).uri,
            )
        }
    }

    @Test func `join host policy is lan only and setup join is console local`() throws {
        #expect(PairingPayload.sanitizeHost("192.0.2.1") == nil)
        #expect(PairingPayload.sanitizeHost("8.8.8.8") == nil)
        #expect(PairingPayload.sanitizeHost("172.16.0.1") == "172.16.0.1")
        #expect(PairingPayload.sanitizeHost("172.15.0.1") == nil)
        #expect(PairingPayload.isBlockedJoinHost("8.8.8.8"))
        #expect(PairingPayload.isBlockedJoinHost("1.1.1.1"))
        #expect(PairingPayload.isBlockedJoinHost("192.0.2.1"))
        #expect(PairingPayload.isBlockedJoinHost("::ffff:8.8.8.8"))
        #expect(!PairingPayload.isBlockedJoinHost("10.0.0.5"))
        #expect(!PairingPayload.isBlockedJoinHost("172.31.255.1"))
        #expect(!PairingPayload.isBlockedJoinHost("fd12:3456:789a::1"))
        #expect(PairingPayload.isBlockedJoinHost("fd00:ec2::254"))
        #expect(PairingPayload.isBlockedJoinHost("2001:db8::1"))
        #expect(PairingPayload.hostResolvesToBlockedAddress("8.8.8.8"))
        #expect(PairingPayload.isConsoleLocalClient("127.0.0.1"))
        #expect(PairingPayload.isConsoleLocalClient("127.1"))
        #expect(PairingPayload.isConsoleLocalClient("::1"))
        #expect(PairingPayload.isConsoleLocalClient("[::1]"))
        #expect(PairingPayload.isConsoleLocalClient("::ffff:127.0.0.1"))
        #expect(PairingPayload.isConsoleLocalClient("localhost"))
        #expect(!PairingPayload.isConsoleLocalClient("192.168.1.10"))
        #expect(!PairingPayload.isConsoleLocalClient("10.0.0.5"))
        #expect(!PairingPayload.isConsoleLocalClient("8.8.8.8"))
        #expect(!PairingPayload.isConsoleLocalClient(nil))
        #expect(!PairingPayload.isConsoleLocalClient(""))
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "8.8.8.8", port: 7_777)
        }
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "192.0.2.1", port: 7_777)
        }
    }

    @Test func `unresolved join host is fail closed and lan ips stay pinned`() throws {
        #expect(PairingPayload.hostResolvesToBlockedAddress("no-such-host.invalid"))
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "no-such-host.invalid", port: 7_777)
        }
        #expect(throws: PairingError.self) {
            try PairingPayload.contractURL(host: "no-such-host.invalid", port: 7_777)
        }
        let pinned = try PairingPayload.resolvedAllowedJoinAddresses("192.168.1.10")
        #expect(pinned.contains("192.168.1.10"))
        #expect(
            PairingPayload.pinnedJoinAddress(preferred: "192.168.1.10", resolved: pinned)
                == "192.168.1.10",
        )
        let redeem = try PairingPayload.redeemURL(host: "192.168.1.10", port: 7_777)
        #expect(redeem.host == "192.168.1.10")
    }

    @Test func `advertised addresses drop loopback link local and public`() {
        let ifaces = [
            HostInterfaceInfo(name: "lo0", ipAddress: "127.0.0.1"),
            HostInterfaceInfo(name: "en0", ipAddress: "192.168.0.4"),
            HostInterfaceInfo(name: "ap0", ipAddress: "169.254.1.1"),
            HostInterfaceInfo(name: "en1", ipAddress: "8.8.8.8"),
            HostInterfaceInfo(name: "en2", ipAddress: "192.0.2.4"),
        ]
        #expect(PairingAddresses.advertisedIPv4(from: ifaces) == ["192.168.0.4"])
    }

    @Test func `advertised addresses include ULA and drop blocked IPv6`() {
        let ifaces = [
            HostInterfaceInfo(name: "lo0", ipAddress: "127.0.0.1"),
            HostInterfaceInfo(name: "lo0", ipAddress: "::1"),
            HostInterfaceInfo(name: "en0", ipAddress: "192.168.0.4"),
            HostInterfaceInfo(name: "en0", ipAddress: "fd12:3456:789a::1"),
            HostInterfaceInfo(name: "en0", ipAddress: "fe80::1"),
            HostInterfaceInfo(name: "en0", ipAddress: "fd00:ec2::254"),
            HostInterfaceInfo(name: "en0", ipAddress: "2001:db8::1"),
        ]
        #expect(
            PairingAddresses.advertisedIPv4(from: ifaces) == [
                "192.168.0.4",
                "fd12:3456:789a::1",
            ],
        )
    }

    @Test func `join host policy allows CGNAT and carves out metadata`() throws {
        #expect(!PairingPayload.isBlockedJoinHost("100.64.0.1"))
        #expect(!PairingPayload.isBlockedJoinHost("100.127.255.254"))
        #expect(!PairingPayload.isBlockedJoinHost("::ffff:100.64.0.1"))
        #expect(PairingPayload.sanitizeHost("100.64.0.1") == "100.64.0.1")
        #expect(PairingPayload.isBlockedJoinHost("100.63.255.255"))
        #expect(PairingPayload.isBlockedJoinHost("100.128.0.0"))
        #expect(PairingPayload.isBlockedJoinHost("100.100.100.200"))
        #expect(PairingPayload.isBlockedJoinHost("::ffff:100.100.100.200"))
        #expect(PairingPayload.sanitizeHost("100.100.100.200") == nil)
        #expect(PairingPayload.isBlockedJoinHost("169.254.1.1"))
        #expect(PairingPayload.isBlockedJoinHost("127.0.0.1"))
        #expect(PairingPayload.isBlockedJoinHost("8.8.8.8"))
        #expect(!PairingPayload.isConsoleLocalClient("100.64.0.1"))
        #expect(PairingPayload.hostResolvesToBlockedAddress("100.100.100.200"))
        #expect(PairingPayload.hostResolvesToBlockedAddress("127.0.0.1"))
        #expect(PairingPayload.hostResolvesToBlockedAddress("8.8.8.8"))
        #expect(!PairingPayload.hostResolvesToBlockedAddress("100.64.0.1"))
        let cgnat = try PairingPayload.redeemURL(host: "100.64.0.1", port: 7_777)
        #expect(cgnat.host == "100.64.0.1")
        #expect(throws: PairingError.self) {
            try PairingPayload.redeemURL(host: "100.100.100.200", port: 7_777)
        }
        #expect(PairingPayload.sanitizeHost("machine.example.ts.net") == "machine.example.ts.net")
        #expect(PairingPayload.sanitizeHost("localhost") == nil)
        #expect(PairingPayload.sanitizeHost("foo.internal") == nil)
        #expect(PairingPayload.sanitizeHost("evil.example/path") == nil)
        #expect(PairingPayload.sanitizeHost("has space") == nil)
        let ifaces = [
            HostInterfaceInfo(name: "lo0", ipAddress: "127.0.0.1"),
            HostInterfaceInfo(name: "en0", ipAddress: "192.168.0.4"),
            HostInterfaceInfo(name: "tun0", ipAddress: "100.64.12.34"),
            HostInterfaceInfo(name: "meta", ipAddress: "100.100.100.200"),
        ]
        #expect(PairingAddresses.advertisedIPv4(from: ifaces) == ["192.168.0.4", "100.64.12.34"])
    }
}
