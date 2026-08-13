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
            host: "192.0.2.10",
            port: 7_777,
            agentPort: 7_778,
            hostId: "host-a",
            fingerprint: "ABCdef",
        )
        let parsed = try PairingPayload.parse(payload.uri)
        #expect(parsed.code == "ABCD-EFGH")
        #expect(parsed.host == "192.0.2.10")
        #expect(parsed.port == 7_777)
        #expect(parsed.agentPort == 7_778)
        #expect(parsed.hostId == "host-a")
        #expect(parsed.fingerprint == "abcdef")
        #expect(throws: PairingError.self) {
            try PairingPayload.parse("https://evil.example/pair")
        }
        #expect(PairingPayload.sanitizeHost("http://x") == nil)
        #expect(PairingPayload.sanitizeHost("192.0.2.1") == "192.0.2.1")
    }

    @Test func `advertised addresses drop loopback and link local`() {
        let ifaces = [
            HostInterfaceInfo(name: "lo0", ipAddress: "127.0.0.1"),
            HostInterfaceInfo(name: "en0", ipAddress: "192.0.2.4"),
            HostInterfaceInfo(name: "ap0", ipAddress: "169.254.1.1"),
        ]
        #expect(PairingAddresses.advertisedIPv4(from: ifaces) == ["192.0.2.4"])
    }
}
