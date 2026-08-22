#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Dispatch
import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the SSRF (Server-Side Request Forgery) protection logic
/// in SSRFGuard (hostname, DNS, Library download URL classifier).
struct SSRFProtectionTests {
    // MARK: - Private Hostnames

    @Test func `localhost blocked`() {
        #expect(SSRFGuard.isPrivateHost("localhost"))
    }

    @Test func `dot local blocked`() {
        #expect(SSRFGuard.isPrivateHost("myhost.local"))
        #expect(SSRFGuard.isPrivateHost("anything.local"))
    }

    @Test func `google metadata blocked`() {
        #expect(SSRFGuard.isPrivateHost("metadata.google.internal"))
    }

    @Test func `internal suffix blocked`() {
        #expect(SSRFGuard.isPrivateHost("service.internal"))
        #expect(SSRFGuard.isPrivateHost("any.deep.internal"))
    }

    // MARK: - Private IPv4 Ranges

    @Test func `current network blocked`() {
        #expect(SSRFGuard.isPrivateHost("0.0.0.0"))
        #expect(SSRFGuard.isPrivateHost("0.1.2.3"))
    }

    @Test func `class 10 blocked`() {
        #expect(SSRFGuard.isPrivateHost("10.0.0.1"))
        #expect(SSRFGuard.isPrivateHost("10.255.255.255"))
    }

    @Test func `loopback blocked`() {
        #expect(SSRFGuard.isPrivateHost("127.0.0.1"))
        #expect(SSRFGuard.isPrivateHost("127.255.255.255"))
    }

    @Test func `range172 private blocked`() {
        #expect(SSRFGuard.isPrivateHost("172.16.0.1"))
        #expect(SSRFGuard.isPrivateHost("172.31.255.255"))
        // 172.15 and 172.32 should NOT be blocked
        #expect(!SSRFGuard.isPrivateHost("172.15.0.1"))
        #expect(!SSRFGuard.isPrivateHost("172.32.0.1"))
    }

    @Test func `range192168 blocked`() {
        #expect(SSRFGuard.isPrivateHost("192.168.0.1"))
        #expect(SSRFGuard.isPrivateHost("192.168.255.255"))
    }

    @Test func `link local blocked`() {
        #expect(SSRFGuard.isPrivateHost("169.254.0.1"))
        #expect(SSRFGuard.isPrivateHost("169.254.255.255"))
    }

    @Test func `multicast blocked`() {
        #expect(SSRFGuard.isPrivateHost("224.0.0.1"))
        #expect(SSRFGuard.isPrivateHost("239.255.255.255"))
    }

    @Test func `reserved high range blocked`() {
        #expect(SSRFGuard.isPrivateHost("240.0.0.0"))
        #expect(SSRFGuard.isPrivateHost("255.255.255.255"))
    }

    // MARK: - Public IPv4 Allowed

    @Test func `public I ps allowed`() {
        #expect(!SSRFGuard.isPrivateHost("8.8.8.8"))
        #expect(!SSRFGuard.isPrivateHost("1.1.1.1"))
        #expect(!SSRFGuard.isPrivateHost("203.0.113.1"))
        #expect(!SSRFGuard.isPrivateHost("93.184.216.34"))
    }

    // MARK: - IPv6

    @Test func `ipv 6 loopback blocked`() {
        #expect(SSRFGuard.isPrivateHost("::1"))
        #expect(SSRFGuard.isPrivateHost("0:0:0:0:0:0:0:1"))
        #expect(SSRFGuard.isPrivateHost("::"))
    }

    @Test func `ipv 6 ULA blocked`() {
        #expect(SSRFGuard.isPrivateHost("fc00::1"))
        #expect(SSRFGuard.isPrivateHost("fd12:3456::1"))
    }

    @Test func `ipv 6 link local blocked`() {
        #expect(SSRFGuard.isPrivateHost("fe80::1"))
    }

    @Test func `ipv 6 bracket stripped`() {
        #expect(SSRFGuard.isPrivateHost("[::1]"))
        #expect(SSRFGuard.isPrivateHost("[fc00::1]"))
    }

    // MARK: - Public Hostnames Allowed

    @Test func `public hostnames allowed`() {
        #expect(!SSRFGuard.isPrivateHost("example.com"))
        #expect(!SSRFGuard.isPrivateHost("github.com"))
        #expect(!SSRFGuard.isPrivateHost("api.example.org"))
    }

    @Test func `resolvedIPStrings returns literal addresses`() {
        #expect(SSRFGuard.resolvedIPStrings("127.0.0.1").contains("127.0.0.1"))
        #expect(SSRFGuard.resolvedIPStrings("192.168.1.10").contains("192.168.1.10"))
    }

    // MARK: - URL Scheme Allowlist

    @Test func `allowed URL schemes`() {
        // Config.allowedURLSchemes should only allow http and https
        #expect(Config.allowedURLSchemes.contains("http"))
        #expect(Config.allowedURLSchemes.contains("https"))
        #expect(!Config.allowedURLSchemes.contains("ftp"))
        #expect(!Config.allowedURLSchemes.contains("file"))
        #expect(!Config.allowedURLSchemes.contains("gopher"))
    }

    // MARK: - validate(url:) DNS classifier

    @Test func `validate URL blocks loopback link local and metadata`() {
        let urls = [
            "http://127.0.0.1/cloud.iso",
            "http://localhost/cloud.iso",
            "http://[::1]/cloud.iso",
            "http://169.254.169.254/latest/meta-data",
            "http://10.1.2.3/img.qcow2",
            "http://192.168.1.9/img.qcow2",
        ]
        for raw in urls {
            let url = URL(string: raw)
            #expect(url != nil)
            if let url {
                #expect(SSRFGuard.validate(url: url) != nil, "expected SSRF reject for \(raw)")
            }
        }
    }

    @Test func `validate URL rejects missing host`() {
        #expect(SSRFGuard.validate(url: URL(fileURLWithPath: "/tmp/cloud.iso")) != nil)
    }

    @Test func `resolvesToPrivateIP uses DNS for loopback literals and localhost`() {
        #expect(SSRFGuard.resolvesToPrivateIP("127.0.0.1"))
        #expect(SSRFGuard.resolvesToPrivateIP("localhost"))
    }

    @Test func `redirect to private host is refused`() {
        let loopback = URL(string: "http://127.0.0.1/secret")
        let metadata = URL(string: "http://169.254.169.254/latest/meta-data")
        let fileURL = URL(string: "file:///etc/passwd")
        #expect(loopback != nil && metadata != nil && fileURL != nil)
        if let loopback {
            #expect(!SSRFGuard.shouldFollowRedirect(to: loopback))
        }
        if let metadata {
            #expect(!SSRFGuard.shouldFollowRedirect(to: metadata))
        }
        if let fileURL {
            #expect(!SSRFGuard.shouldFollowRedirect(to: fileURL))
        }
    }

    @Test func `image controller download path uses validate not hostname only`() {
        #expect(ImageController.downloadURLRejection("file:///tmp/a.iso") != nil)
        #expect(ImageController.downloadURLRejection("ftp://example.com/a.iso") != nil)
        #expect(ImageController.downloadURLRejection("http://127.0.0.1/a.iso") != nil)
        #expect(ImageController.downloadURLRejection("http://localhost/a.iso") != nil)
        #expect(ImageController.downloadURLRejection("http://169.254.169.254/a.iso") != nil)
        #expect(ImageController.downloadURLRejection("not-a-url") != nil)
        let publicURL = ImageController.downloadURLRejection("https://cloud-images.ubuntu.com/releases/a.img")
        #expect(publicURL == nil)
    }

    @Test func `library download session does not follow redirect to loopback`() async throws {
        let target = try LocalRedirectHTTPServer(location: "http://127.0.0.1:9/secret")
        defer { target.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(target.port)/image.iso"))
        // 127.0.0.1 itself is private, so validate rejects before fetch. Prove the
        // hop gate: session must not follow Location even if the first URL were public.
        let privateLocation = try #require(URL(string: "http://127.0.0.1:9/secret"))
        #expect(!SSRFGuard.shouldFollowRedirect(to: privateLocation))
        let session = SSRFGuard.urlSession(resourceTimeout: 5)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect((300 ... 399).contains(http.statusCode))
        #expect(target.connectionCount == 1)
    }
}

/// Serves a 302 so tests can prove Library URLSession does not follow a private Location.
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
        if ready.wait(timeout: .now() + .seconds(5)) != .success {
            close(sock)
            throw BarkVisorError.badRequest("accept thread did not start")
        }
    }

    func stop() {
        close(fd)
    }
}
