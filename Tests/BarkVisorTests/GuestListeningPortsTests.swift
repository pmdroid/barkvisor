import Foundation
import Testing
@testable import BarkVisorCore

struct GuestListeningPortsTests {
    @Test func `ss output parses tcp listen only`() {
        let text = """
        State Recv-Q Send-Q Local Address:Port Peer Address:Port
        LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
        LISTEN 0 511 127.0.0.1:3000 0.0.0.0:*
        LISTEN 0 128 [::]:80 [::]:*
        UNCONN 0 0 0.0.0.0:68 0.0.0.0:*
        """
        let ports = GuestListeningPorts.parseCommandOutput(text)
        #expect(ports.map(\.port) == [22, 80, 3_000])
        #expect(ports.allSatisfy { $0.proto == "tcp" })
        #expect(ports.first { $0.port == 22 }?.label == "SSH")
        #expect(ports.first { $0.port == 80 }?.label == "HTTP")
        #expect(ports.first { $0.port == 3_000 }?.label == "Dev")
        #expect(ports.first { $0.port == 22 }?.scope == GuestListeningPorts.scopeNetwork)
        #expect(ports.first { $0.port == 3_000 }?.scope == GuestListeningPorts.scopeInternal)
        #expect(ports.first { $0.port == 80 }?.address == "::")
    }

    @Test func `netstat output ignores udp`() {
        let text = """
        Active Internet connections
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN
        tcp6       0      0 :::22                   :::*                    LISTEN
        udp        0      0 0.0.0.0:53              0.0.0.0:*
        """
        let ports = GuestListeningPorts.parseCommandOutput(text)
        #expect(Set(ports.map(\.port)) == [22, 443])
        #expect(ports.first { $0.port == 443 }?.label == "HTTPS")
        #expect(ports.first { $0.port == 22 }?.address == "::")
    }

    @Test func `empty listen list is none not invented`() {
        #expect(GuestListeningPorts.parseCommandOutput("").isEmpty)
        #expect(GuestListeningPorts.parseCommandOutput("State Recv-Q\n").isEmpty)
    }

    @Test func `proc net tcp listen only`() {
        let tail = "00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000"
        let tcp = """
          sl  local_address rem_address   st tx_queue rx_queue
           0: 00000000:0016 00000000:0000 0A \(tail)
           1: 0100007F:1F90 00000000:0000 0A \(tail)
           2: 0A01A8C0:0050 0B01A8C0:C350 01 \(tail)
        """
        let zero6 = "00000000000000000000000000000000"
        let loop6 = "00000000000000000000000001000000"
        let tcp6 = """
          sl  local_address rem_address st
           0: \(zero6):01BB \(zero6):0000 0A \(tail)
           1: \(loop6):0BB8 \(zero6):0000 0A \(tail)
        """
        let ports = GuestListeningPorts.parseProcNet(tcp: tcp, tcp6: tcp6)
        #expect(ports.map(\.port) == [22, 443, 3_000, 8_080])
        #expect(ports.first { $0.port == 22 }?.address == "0.0.0.0")
        #expect(ports.first { $0.port == 8_080 }?.address == "127.0.0.1")
        #expect(ports.first { $0.port == 8_080 }?.scope == GuestListeningPorts.scopeInternal)
        #expect(ports.first { $0.port == 443 }?.address == "::")
        #expect(ports.first { $0.port == 3_000 }?.address == "::1")
        #expect(ports.contains { $0.port == 80 } == false)
    }

    @Test func `ipv4 hex is little endian`() {
        #expect(GuestListeningPorts.decodeIPv4Hex("00000000") == "0.0.0.0")
        #expect(GuestListeningPorts.decodeIPv4Hex("0100007F") == "127.0.0.1")
        #expect(GuestListeningPorts.decodeIPv4Hex("0A01A8C0") == "192.168.1.10")
    }

    @Test func `change only persist keeps timestamp`() throws {
        let ssh = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 22))
        let json = GuestListeningPorts.encodeJSON([ssh])
        let same = GuestListeningPorts.persistFields(
            collected: [ssh],
            previousJSON: json,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(same.json == json)
        #expect(same.collectedAt == "t1")

        let empty = GuestListeningPorts.persistFields(
            collected: [],
            previousJSON: json,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(empty.json == "[]")
        #expect(empty.collectedAt == "t2")

        let failed = GuestListeningPorts.persistFields(
            collected: nil,
            previousJSON: json,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(failed.json == json)
        #expect(failed.collectedAt == "t1")

        let reshuffled = #"[{"scope":"network","port":22,"label":"SSH","address":"0.0.0.0","proto":"tcp"}]"#
        let sameKeys = GuestListeningPorts.persistFields(
            collected: [ssh],
            previousJSON: reshuffled,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(sameKeys.json == reshuffled)
        #expect(sameKeys.collectedAt == "t1")
    }

    @Test func `loopback is never a network scope`() {
        #expect(GuestListeningPorts.scope(for: "127.0.0.1") == GuestListeningPorts.scopeInternal)
        #expect(GuestListeningPorts.scope(for: "::1") == GuestListeningPorts.scopeInternal)
        #expect(GuestListeningPorts.scope(for: "0.0.0.0") == GuestListeningPorts.scopeNetwork)
        #expect(GuestListeningPorts.isWildcardAddress("::"))
        #expect(!GuestListeningPorts.isLoopbackAddress("10.0.0.5"))
    }

    @Test func `collect interval skips until marked`() {
        let id = "vm-ports-\(UUID().uuidString)"
        defer { GuestListeningPorts.clearAttempt(vmID: id) }
        let t0 = Date()
        #expect(GuestListeningPorts.shouldCollect(vmID: id, now: t0, interval: 30))
        GuestListeningPorts.markCollected(vmID: id, now: t0)
        #expect(!GuestListeningPorts.shouldCollect(vmID: id, now: t0.addingTimeInterval(10), interval: 30))
        #expect(GuestListeningPorts.shouldCollect(vmID: id, now: t0.addingTimeInterval(31), interval: 30))

        GuestListeningPorts.markCollected(vmID: id, now: t0, succeeded: false)
        #expect(!GuestListeningPorts.shouldCollect(vmID: id, now: t0.addingTimeInterval(30)))
        #expect(!GuestListeningPorts.shouldCollect(vmID: id, now: t0.addingTimeInterval(299)))
        #expect(GuestListeningPorts.shouldCollect(vmID: id, now: t0.addingTimeInterval(301)))
    }
}
