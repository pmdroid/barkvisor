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
        #expect(same.changed == false)

        let empty = GuestListeningPorts.persistFields(
            collected: [],
            previousJSON: json,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(empty.json == "[]")
        #expect(empty.collectedAt == "t2")
        #expect(empty.changed == true)

        let failed = GuestListeningPorts.persistFields(
            collected: nil,
            previousJSON: json,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(failed.json == nil)
        #expect(failed.collectedAt == nil)
        #expect(failed.changed == true)

        let alreadyNil = GuestListeningPorts.persistFields(
            collected: nil,
            previousJSON: nil,
            previousCollectedAt: nil,
            now: "t2",
        )
        #expect(alreadyNil.json == nil)
        #expect(alreadyNil.changed == false)

        let reshuffled = #"[{"scope":"network","port":22,"label":"SSH","address":"0.0.0.0","proto":"tcp"}]"#
        let sameKeys = GuestListeningPorts.persistFields(
            collected: [ssh],
            previousJSON: reshuffled,
            previousCollectedAt: "t1",
            now: "t2",
        )
        #expect(sameKeys.json == reshuffled)
        #expect(sameKeys.collectedAt == "t1")
        #expect(sameKeys.changed == false)
    }

    @Test func `canonicalize puts labeled ports first`() throws {
        let smtp = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 25))
        let http = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 80))
        let high = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 40_000))
        let ordered = GuestListeningPorts.canonicalize([smtp, high, http])
        #expect(ordered.map(\.port) == [80, 25, 40_000])
        #expect(ordered.first?.label == "HTTP")
    }

    @Test func `collect budget is a shared 3s wall`() {
        let t0 = Date()
        #expect(GuestListeningPorts.collectTimeoutSeconds == 3)
        #expect(GuestListeningPorts.remainingCollectBudget(
            until: t0.addingTimeInterval(3),
            now: t0,
        ) == 3)
        #expect(GuestListeningPorts.remainingCollectBudget(
            until: t0,
            now: t0.addingTimeInterval(1),
        ) == 0)
    }

    @Test func `guest exec out-data is byte bounded`() {
        let ok = Data("LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n".utf8).base64EncodedString()
        #expect(GuestListeningPorts.decodeBoundedOutput(ok)?.contains(":22") == true)
        let huge = Data(repeating: 0x41, count: GuestListeningPorts.execOutputMaxBytes + 1)
            .base64EncodedString()
        #expect(GuestListeningPorts.decodeBoundedOutput(huge) == nil)
        #expect(GuestListeningPorts.decodeBoundedOutput(nil) == nil)
    }

    @Test func `published filter keeps common ports only`() {
        let rpc = GuestListeningPorts.makePort(address: "0.0.0.0", port: 111)
        let sshd = GuestListeningPorts.makePort(address: "0.0.0.0", port: 22)
        let vite = GuestListeningPorts.makePort(address: "0.0.0.0", port: 5_173)
        let mdns = GuestListeningPorts.makePort(address: "0.0.0.0", port: 5_353)
        let kept = GuestListeningPorts.selectPublished([rpc, sshd, vite, mdns].compactMap(\.self))
        #expect(Set(kept.map(\.port)) == [22, 5_173])
        #expect(GuestListeningPorts.isPublishedPort(8_081))
        #expect(GuestListeningPorts.isPublishedPort(8_123))
        #expect(GuestListeningPorts.isPublishedPort(8_096))
        #expect(GuestListeningPorts.isPublishedPort(32_400))
        #expect(GuestListeningPorts.isPublishedPort(18_789))
        #expect(GuestListeningPorts.label(for: 8_123) == "Home Assistant")
        #expect(GuestListeningPorts.label(for: 8_096) == "Jellyfin")
        #expect(GuestListeningPorts.label(for: 32_400) == "Plex")
        #expect(GuestListeningPorts.label(for: 18_789) == "OpenClaw")
        #expect(GuestListeningPorts.impliedScheme(for: 8_123) == "http")
        #expect(!GuestListeningPorts.isPublishedPort(8_006))
        #expect(!GuestListeningPorts.isPublishedPort(111))
    }

    @Test func `http scheme follows probe then well-known fallback`() throws {
        let http = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 80))
        let ssh = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 22))
        let mysql = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 3_306))
        let probed = GuestListeningPorts.applyHTTPSchemes(
            [http, ssh, mysql],
            probedHTTP: [80],
            probeRan: true,
        )
        #expect(probed.first { $0.port == 80 }?.scheme == "http")
        #expect(probed.first { $0.port == 22 }?.scheme == nil)
        #expect(probed.first { $0.port == 3_306 }?.scheme == nil)

        let notHttp = GuestListeningPorts.applyHTTPSchemes(
            [http],
            probedHTTP: [],
            probeRan: true,
        )
        #expect(notHttp.first?.scheme == nil)

        let fallback = GuestListeningPorts.applyHTTPSchemes(
            [http],
            probedHTTP: [],
            probeRan: false,
        )
        #expect(fallback.first?.scheme == "http")

        let https = try #require(GuestListeningPorts.makePort(address: "0.0.0.0", port: 443))
        let tls = GuestListeningPorts.applyHTTPSchemes(
            [https],
            probedHTTP: [],
            probeRan: true,
        )
        #expect(tls.first?.scheme == "https")
    }

    @Test func `windows netstat ano parses tcp listening`() {
        let text = """
        Active Connections

          Proto  Local Address          Foreign Address        State           PID
          TCP    0.0.0.0:22             0.0.0.0:0              LISTENING       4120
          TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       892
          TCP    127.0.0.1:3000         0.0.0.0:0              LISTENING       5678
          TCP    192.168.1.50:3389      0.0.0.0:0              LISTENING       1232
          TCP    [::]:80                [::]:0                 LISTENING       4
          TCP    192.168.1.50:49812     13.107.5.93:443        ESTABLISHED     2000
          UDP    0.0.0.0:500            *:*                                    1234
          UDP    0.0.0.0:3389           *:*                                    1232
        """
        let ports = GuestListeningPorts.parseWindowsOutput(text)
        #expect(Set(ports.map(\.port)) == [22, 80, 135, 3_000, 3_389])
        #expect(ports.contains { $0.port == 500 } == false)
        #expect(ports.first { $0.port == 3_000 }?.scope == GuestListeningPorts.scopeInternal)
        #expect(ports.first { $0.port == 80 }?.address == "::")
        #expect(ports.first { $0.port == 3_389 }?.label == "RDP")

        let published = GuestListeningPorts.selectPublished(ports)
        #expect(Set(published.map(\.port)) == [22, 80, 3_000, 3_389])
        let implied = GuestListeningPorts.applyHTTPSchemes(
            published,
            probedHTTP: [],
            probeRan: false,
        )
        #expect(implied.first { $0.port == 80 }?.scheme == "http")
        #expect(implied.first { $0.port == 22 }?.scheme == nil)
        #expect(implied.first { $0.port == 3_389 }?.scheme == nil)
    }

    @Test func `windows powershell table and csv parse listen rows`() {
        let table = """
        LocalAddress                        LocalPort RemoteAddress                       RemotePort State       AppliedSetting OwningProcess
        ------------                        --------- -------------                       ---------- -----       -------------- -------------
        0.0.0.0                                    22 0.0.0.0                                    0 Listen                      4120
        127.0.0.1                                3000 0.0.0.0                                    0 Listen                      5678
        ::                                         80 ::                                         0 Listen                      4
        ::                                       3389 ::                                         0 Listen                      1232
        """
        let tablePorts = GuestListeningPorts.parsePowerShellNetTCP(table)
        #expect(Set(tablePorts.map(\.port)) == [22, 80, 3_000, 3_389])
        #expect(tablePorts.first { $0.port == 80 }?.address == "::")

        let csv = """
        "LocalAddress","LocalPort","State"
        "0.0.0.0","22","Listen"
        "127.0.0.1","3000","Listen"
        "::","80","Listen"
        "192.168.1.50","49812","Established"
        """
        let csvPorts = GuestListeningPorts.parsePowerShellNetTCP(csv)
        #expect(Set(csvPorts.map(\.port)) == [22, 80, 3_000])

        let listed = """
        LocalAddress : 0.0.0.0
        LocalPort    : 22
        State        : Listen

        LocalAddress : 127.0.0.1
        LocalPort    : 3000
        State        : Listen
        """
        let listPorts = GuestListeningPorts.parsePowerShellNetTCP(listed)
        #expect(Set(listPorts.map(\.port)) == [22, 3_000])
        #expect(listPorts.first { $0.port == 3_000 }?.scope == GuestListeningPorts.scopeInternal)

        let compact = """
        0.0.0.0 443 LISTEN
        127.0.0.1 5173 LISTEN
        """
        let compactPorts = GuestListeningPorts.parseWindowsOutput(compact)
        #expect(Set(compactPorts.map(\.port)) == [443, 5_173])
        #expect(compactPorts.first { $0.port == 443 }?.label == "HTTPS")
    }

    @Test func `localized windows netstat listen rows are not dropped`() {
        let german = """
        Aktive Verbindungen

          Proto  Lokale Adresse          Remoteadresse           Status
          TCP    0.0.0.0:22             0.0.0.0:0              ABHÖREN       4120
          TCP    127.0.0.1:3000         0.0.0.0:0              ABHÖREN       5678
          TCP    [::]:80                [::]:0                 ABHÖREN       4
          TCP    192.168.1.50:49812     13.107.5.93:443        HERGESTELLT   2000
          UDP    0.0.0.0:500            *:*                                    1234
        """
        let ports = GuestListeningPorts.parseWindowsOutput(german)
        #expect(Set(ports.map(\.port)) == [22, 80, 3_000])
        #expect(ports.contains { $0.port == 49_812 } == false)
        #expect(GuestListeningPorts.isListenState("ABHÖREN"))
        #expect(GuestListeningPorts.isListenState("ÉCOUTE"))
        #expect(!GuestListeningPorts.isListenState("HERGESTELLT"))
        #expect(!GuestListeningPorts.isListenState("ESTABLISHED"))
    }

    @Test func `empty windows parse falls through to later snapshots`() {
        var laterCalls = 0
        let germanNoEnglish = """
          TCP    0.0.0.0:135            0.0.0.0:0              ABHÖREN       892
        """
        let powershellEnglish = """
        0.0.0.0 443 LISTEN
        127.0.0.1 5173 LISTEN
        """
        let establishedOnly = """
          TCP    192.168.1.50:49812     13.107.5.93:443        ESTABLISHED     2000
        """

        let skippedEmpty = GuestListeningPorts.firstNonEmptyWindowsParse([
            { establishedOnly },
            {
                laterCalls += 1
                return powershellEnglish
            },
        ])
        #expect(Set(skippedEmpty?.map(\.port) ?? []) == [443, 5_173])
        #expect(laterCalls == 1)

        laterCalls = 0
        let germanFirst = GuestListeningPorts.firstNonEmptyWindowsParse([
            { germanNoEnglish },
            {
                laterCalls += 1
                return powershellEnglish
            },
        ])
        #expect(germanFirst?.map(\.port) == [135])
        #expect(laterCalls == 0)

        #expect(GuestListeningPorts.firstNonEmptyWindowsParse([
            { nil },
            { nil },
        ]) == nil)
        let emptySuccess = GuestListeningPorts.firstNonEmptyWindowsParse([
            { establishedOnly },
        ])
        #expect(emptySuccess != nil)
        #expect(emptySuccess?.isEmpty == true)
    }

    @Test func `windows guest hint skips unix collect path`() {
        #expect(GuestListeningPorts.looksLikeWindows("mswindows Microsoft Windows"))
        #expect(GuestListeningPorts.looksLikeWindows("windows-amd64"))
        #expect(GuestListeningPorts.looksLikeWindows("windows-arm64"))
        #expect(!GuestListeningPorts.looksLikeWindows("linux-amd64 Ubuntu"))
        #expect(!GuestListeningPorts.looksLikeWindows(nil))
        #expect(!GuestListeningPorts.looksLikeWindows(""))
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
