#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
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
        #expect(SSRFGuard.isPrivateHost("fe90::1"))
        #expect(SSRFGuard.isPrivateHost("febf::1"))
        #expect(!SSRFGuard.isPrivateHost("fec0::1"))
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

    @Test func `library download session does not follow redirect to loopback`() throws {
        let privateLocation = try #require(URL(string: "http://127.0.0.1:9/secret"))
        #expect(!SSRFGuard.shouldFollowRedirect(to: privateLocation))
        let fileHop = try #require(URL(string: "file:///etc/passwd"))
        #expect(!SSRFGuard.shouldFollowRedirect(to: fileHop))
    }

    @Test func `pinned session refuses loopback before connect`() async throws {
        let url = try #require(URL(string: "http://127.0.0.1/image.iso"))
        let session = SSRFGuard.urlSession(resourceTimeout: 5)
        defer { session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: url)
        }
    }

    @Test func `fetchRejection blocks file and ftp schemes`() throws {
        let fileWithHost = try #require(URL(string: "file://cloud-images.ubuntu.com/etc/passwd"))
        let ftp = try #require(URL(string: "ftp://example.com/a.iso"))
        #expect(SSRFGuard.fetchRejection(for: fileWithHost) != nil)
        #expect(SSRFGuard.fetchRejection(for: ftp) != nil)
    }

    @Test func `redirectTarget refuses private and file hops`() throws {
        let from = try #require(URL(string: "https://cdn.example/a.img"))
        let relative = SSRFGuard.redirectTarget(statusCode: 302, location: "/b.img", from: from)
        #expect(relative?.absoluteString == "https://cdn.example/b.img")
        #expect(SSRFGuard.redirectTarget(statusCode: 200, location: "/b.img", from: from) == nil)

        let loopback = try #require(
            SSRFGuard.redirectTarget(
                statusCode: 302, location: "http://127.0.0.1/secret", from: from,
            ),
        )
        #expect(!SSRFGuard.shouldFollowRedirect(to: loopback))
        #expect(throws: SSRFPinError.self) {
            _ = try SSRFGuard.pinEndpoint(url: loopback)
        }

        let fileHop = try #require(
            SSRFGuard.redirectTarget(
                statusCode: 302, location: "file:///etc/passwd", from: from,
            ),
        )
        #expect(!SSRFGuard.shouldFollowRedirect(to: fileHop))
        #expect(SSRFGuard.fetchRejection(for: fileHop) != nil)
    }

    @Test func `pinEndpoint keeps SNI host and drops private answers`() throws {
        let url = try #require(URL(string: "https://cloud-images.example/img.qcow2"))

        let pin = try SSRFGuard.pinEndpoint(url: url, resolvedIPs: ["93.184.216.34", "1.1.1.1"])
        #expect(pin.originalHost == "cloud-images.example")
        #expect(pin.connectIP == "93.184.216.34")
        #expect(pin.port == 443)
        #expect(pin.usesTLS)

        do {
            _ = try SSRFGuard.pinEndpoint(url: url, resolvedIPs: ["1.1.1.1", "127.0.0.1"])
            Issue.record("mixed public/private answers must not pin")
        } catch let SSRFPinError.rejected(message) {
            #expect(message.contains("private"))
        }

        do {
            _ = try SSRFGuard.pinEndpoint(url: url, resolvedIPs: [])
            Issue.record("empty DNS must not pin")
        } catch let SSRFPinError.rejected(message) {
            #expect(message.contains("could not be resolved"))
        }

        let fileURL = try #require(URL(string: "file://cloud-images.example/etc/passwd"))
        #expect(throws: SSRFPinError.self) {
            _ = try SSRFGuard.pinEndpoint(url: fileURL, resolvedIPs: ["93.184.216.34"])
        }
    }
}
