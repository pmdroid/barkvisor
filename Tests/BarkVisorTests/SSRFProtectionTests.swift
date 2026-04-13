import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the SSRF (Server-Side Request Forgery) protection logic
/// in SSRFGuard.isPrivateHost.
@Suite struct SSRFProtectionTests {
    // MARK: - Private Hostnames

    @Test func localhostBlocked() {
        #expect(SSRFGuard.isPrivateHost("localhost"))
    }

    @Test func dotLocalBlocked() {
        #expect(SSRFGuard.isPrivateHost("myhost.local"))
        #expect(SSRFGuard.isPrivateHost("anything.local"))
    }

    @Test func googleMetadataBlocked() {
        #expect(SSRFGuard.isPrivateHost("metadata.google.internal"))
    }

    @Test func internalSuffixBlocked() {
        #expect(SSRFGuard.isPrivateHost("service.internal"))
        #expect(SSRFGuard.isPrivateHost("any.deep.internal"))
    }

    // MARK: - Private IPv4 Ranges

    @Test func currentNetworkBlocked() {
        #expect(SSRFGuard.isPrivateHost("0.0.0.0"))
        #expect(SSRFGuard.isPrivateHost("0.1.2.3"))
    }

    @Test func class10Blocked() {
        #expect(SSRFGuard.isPrivateHost("10.0.0.1"))
        #expect(SSRFGuard.isPrivateHost("10.255.255.255"))
    }

    @Test func loopbackBlocked() {
        #expect(SSRFGuard.isPrivateHost("127.0.0.1"))
        #expect(SSRFGuard.isPrivateHost("127.255.255.255"))
    }

    @Test func test172PrivateRangeBlocked() {
        #expect(SSRFGuard.isPrivateHost("172.16.0.1"))
        #expect(SSRFGuard.isPrivateHost("172.31.255.255"))
        // 172.15 and 172.32 should NOT be blocked
        #expect(!SSRFGuard.isPrivateHost("172.15.0.1"))
        #expect(!SSRFGuard.isPrivateHost("172.32.0.1"))
    }

    @Test func test192168Blocked() {
        #expect(SSRFGuard.isPrivateHost("192.168.0.1"))
        #expect(SSRFGuard.isPrivateHost("192.168.255.255"))
    }

    @Test func linkLocalBlocked() {
        #expect(SSRFGuard.isPrivateHost("169.254.0.1"))
        #expect(SSRFGuard.isPrivateHost("169.254.255.255"))
    }

    @Test func multicastBlocked() {
        #expect(SSRFGuard.isPrivateHost("224.0.0.1"))
        #expect(SSRFGuard.isPrivateHost("239.255.255.255"))
    }

    @Test func reservedHighRangeBlocked() {
        #expect(SSRFGuard.isPrivateHost("240.0.0.0"))
        #expect(SSRFGuard.isPrivateHost("255.255.255.255"))
    }

    // MARK: - Public IPv4 Allowed

    @Test func publicIPsAllowed() {
        #expect(!SSRFGuard.isPrivateHost("8.8.8.8"))
        #expect(!SSRFGuard.isPrivateHost("1.1.1.1"))
        #expect(!SSRFGuard.isPrivateHost("203.0.113.1"))
        #expect(!SSRFGuard.isPrivateHost("93.184.216.34"))
    }

    // MARK: - IPv6

    @Test func ipv6LoopbackBlocked() {
        #expect(SSRFGuard.isPrivateHost("::1"))
        #expect(SSRFGuard.isPrivateHost("0:0:0:0:0:0:0:1"))
        #expect(SSRFGuard.isPrivateHost("::"))
    }

    @Test func ipv6ULABlocked() {
        #expect(SSRFGuard.isPrivateHost("fc00::1"))
        #expect(SSRFGuard.isPrivateHost("fd12:3456::1"))
    }

    @Test func ipv6LinkLocalBlocked() {
        #expect(SSRFGuard.isPrivateHost("fe80::1"))
    }

    @Test func ipv6BracketStripped() {
        #expect(SSRFGuard.isPrivateHost("[::1]"))
        #expect(SSRFGuard.isPrivateHost("[fc00::1]"))
    }

    // MARK: - Public Hostnames Allowed

    @Test func publicHostnamesAllowed() {
        #expect(!SSRFGuard.isPrivateHost("example.com"))
        #expect(!SSRFGuard.isPrivateHost("github.com"))
        #expect(!SSRFGuard.isPrivateHost("api.example.org"))
    }

    // MARK: - URL Scheme Allowlist

    @Test func allowedURLSchemes() {
        // Config.allowedURLSchemes should only allow http and https
        #expect(Config.allowedURLSchemes.contains("http"))
        #expect(Config.allowedURLSchemes.contains("https"))
        #expect(!Config.allowedURLSchemes.contains("ftp"))
        #expect(!Config.allowedURLSchemes.contains("file"))
        #expect(!Config.allowedURLSchemes.contains("gopher"))
    }
}
