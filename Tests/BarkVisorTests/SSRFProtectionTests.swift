import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the SSRF (Server-Side Request Forgery) protection logic
/// in SSRFGuard.isPrivateHost.
final class SSRFProtectionTests: XCTestCase {
    // MARK: - Private Hostnames

    func testLocalhostBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("localhost"))
    }

    func testDotLocalBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("myhost.local"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("anything.local"))
    }

    func testGoogleMetadataBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("metadata.google.internal"))
    }

    func testInternalSuffixBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("service.internal"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("any.deep.internal"))
    }

    // MARK: - Private IPv4 Ranges

    func testCurrentNetworkBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("0.0.0.0"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("0.1.2.3"))
    }

    func testClass10Blocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("10.0.0.1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("10.255.255.255"))
    }

    func testLoopbackBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("127.0.0.1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("127.255.255.255"))
    }

    func test172PrivateRangeBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("172.16.0.1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("172.31.255.255"))
        // 172.15 and 172.32 should NOT be blocked
        XCTAssertFalse(SSRFGuard.isPrivateHost("172.15.0.1"))
        XCTAssertFalse(SSRFGuard.isPrivateHost("172.32.0.1"))
    }

    func test192168Blocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("192.168.0.1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("192.168.255.255"))
    }

    func testLinkLocalBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("169.254.0.1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("169.254.255.255"))
    }

    func testMulticastBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("224.0.0.1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("239.255.255.255"))
    }

    func testReservedHighRangeBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("240.0.0.0"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("255.255.255.255"))
    }

    // MARK: - Public IPv4 Allowed

    func testPublicIPsAllowed() {
        XCTAssertFalse(SSRFGuard.isPrivateHost("8.8.8.8"))
        XCTAssertFalse(SSRFGuard.isPrivateHost("1.1.1.1"))
        XCTAssertFalse(SSRFGuard.isPrivateHost("203.0.113.1"))
        XCTAssertFalse(SSRFGuard.isPrivateHost("93.184.216.34"))
    }

    // MARK: - IPv6

    func testIPv6LoopbackBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("::1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("0:0:0:0:0:0:0:1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("::"))
    }

    func testIPv6ULABlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("fc00::1"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("fd12:3456::1"))
    }

    func testIPv6LinkLocalBlocked() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("fe80::1"))
    }

    func testIPv6BracketStripped() {
        XCTAssertTrue(SSRFGuard.isPrivateHost("[::1]"))
        XCTAssertTrue(SSRFGuard.isPrivateHost("[fc00::1]"))
    }

    // MARK: - Public Hostnames Allowed

    func testPublicHostnamesAllowed() {
        XCTAssertFalse(SSRFGuard.isPrivateHost("example.com"))
        XCTAssertFalse(SSRFGuard.isPrivateHost("github.com"))
        XCTAssertFalse(SSRFGuard.isPrivateHost("api.example.org"))
    }

    // MARK: - URL Scheme Allowlist

    func testAllowedURLSchemes() {
        // Config.allowedURLSchemes should only allow http and https
        XCTAssertTrue(Config.allowedURLSchemes.contains("http"))
        XCTAssertTrue(Config.allowedURLSchemes.contains("https"))
        XCTAssertFalse(Config.allowedURLSchemes.contains("ftp"))
        XCTAssertFalse(Config.allowedURLSchemes.contains("file"))
        XCTAssertFalse(Config.allowedURLSchemes.contains("gopher"))
    }
}
