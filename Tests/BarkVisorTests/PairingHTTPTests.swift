#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Dispatch
import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Pairing HTTP (PAS-45)")
struct PairingHTTPTests {
    private func isolatedDir(_ label: String = "pair-http") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `redeem rejects omitted apiVersion`() throws {
        let dir = try isolatedDir()
        let joinerDir = try isolatedDir("jav")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let csr = try HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM)
        var request = PairingRedeemRequest(
            code: issued.code,
            hostId: joiner.hostId,
            csrPEM: csr,
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
        let encoded = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "apiVersion")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        request = try JSONDecoder().decode(PairingRedeemRequest.self, from: stripped)
        #expect(request.apiVersion == nil)
        #expect(throws: PairingError.incompatibleAPIVersion(
            got: 0,
            expected: APIContract.version,
        )) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: request,
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.consumedAt == nil)
    }

    @Test func `consumed code replay honors offer expiry`() throws {
        let dir = try isolatedDir("replay-ttl")
        let joinerDir = try isolatedDir("replay-ttl-j")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let now = Date()
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                ttl: 30,
                now: now,
            ),
            offers: offers,
        )
        let csr = try HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM)
        let request = PairingRedeemRequest(
            code: issued.code,
            hostId: joiner.hostId,
            csrPEM: csr,
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir, issuerHostId: issuerId, request: request, now: now,
            ),
            offers: offers,
        )
        #expect(try offers.load()?.consumedAt != nil)
        #expect(throws: PairingError.expiredOrUsed) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: request,
                    now: now.addingTimeInterval(31),
                ),
                offers: offers,
            )
        }
        #expect(try PeerPinStore(dataDir: dir).load().count == 1)
    }

    @Test func `pairing HTTP client does not follow redirects`() async throws {
        let server = try LocalRedirectHTTPServer(location: "http://127.0.0.1:9/api/contract")
        defer { server.stop() }
        // Default timeout: a 2s budget expires under parallel CI load.
        let client = URLSessionPairingHTTPClient()
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/api/contract"))
        let response = try await client.get(url: url)
        #expect((300 ... 399).contains(response.status))
        #expect(server.connectionCount == 1)
    }

    @Test func `issue advertisedHost valid persists and invalid is 400`() throws {
        let dir = try isolatedDir("adv-host")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "100.64.1.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        #expect(issued.advertisedHost == "100.64.1.8")
        #expect(issued.qrPayload.contains("host=100.64.1.8"))
        #expect(PairingError.invalidPayload("x").httpStatus == 400)
        #expect(throws: PairingError.self) {
            try PairingService.issue(
                PairingService.IssueInput(
                    dataDir: dir,
                    hostId: hostId,
                    advertisedHost: "localhost",
                    advertisedHosts: ["192.168.0.8"],
                ),
                offers: offers,
            )
        }
        #expect(try offers.load()?.advertisedHost == "100.64.1.8")
    }

    @Test func `setup window join stays console local even for CGNAT peers`() {
        #expect(PairingPayload.isConsoleLocalClient("127.0.0.1"))
        #expect(!PairingPayload.isConsoleLocalClient("192.168.1.10"))
        #expect(!PairingPayload.isConsoleLocalClient("100.64.0.1"))
        #expect(!PairingPayload.isConsoleLocalClient("10.0.0.5"))
    }
}

/// Serves a 302 so tests can prove pairing HTTP does not follow it.
private final class LocalRedirectHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var _connections = 0

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _connections
    }

    init(location: String) throws {
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
        // Dedicated thread: global GCD is starved by parallel Swift Testing.
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [fd = sock, location] in
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
                self.lock.lock()
                self._connections += 1
                self.lock.unlock()
                var buf = [UInt8](repeating: 0, count: 1_024)
                _ = read(client, &buf, buf.count)
                let payload = Data(
                    "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .utf8,
                )
                payload.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = write(client, base, raw.count)
                }
                close(client)
            }
        }
        // Bounded so a stuck accept thread fails this test instead of hanging CI.
        if ready.wait(timeout: .now() + .seconds(5)) != .success {
            close(sock)
            throw BarkVisorError.badRequest("accept thread did not start")
        }
    }

    func stop() {
        close(fd)
    }
}
