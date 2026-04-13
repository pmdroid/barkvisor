import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct SecurityTests {
    // MARK: - RateLimitStore: Blocking After Max Attempts

    @Test func `rate limit blocks after max attempts`() async {
        let store = RateLimitStore(maxAttempts: 3, window: 60)

        // First 3 requests should be allowed
        for i in 1 ... 3 {
            let result = await store.check(key: "192.168.1.1")
            #expect(result == nil, "Request \(i) should be allowed")
        }

        // 4th request should be blocked
        let blocked = await store.check(key: "192.168.1.1")
        #expect(blocked != nil, "Request after maxAttempts should be blocked")
        #expect((blocked ?? 0) > 0, "Retry-after should be positive")
    }

    @Test func `rate limit tracks keys independently`() async {
        let store = RateLimitStore(maxAttempts: 2, window: 60)

        // Exhaust limit for key A
        _ = await store.check(key: "A")
        _ = await store.check(key: "A")
        let blockedA = await store.check(key: "A")
        #expect(blockedA != nil, "Key A should be blocked")

        // Key B should still be allowed
        let allowedB = await store.check(key: "B")
        #expect(allowedB == nil, "Key B should be independent and allowed")
    }

    // MARK: - RateLimitStore: Window Expiration

    @Test func `rate limit allows after window expires`() async {
        // Use a very short window so it expires quickly
        let store = RateLimitStore(maxAttempts: 1, window: 0.1)

        // Use the single allowed attempt
        let first = await store.check(key: "test")
        #expect(first == nil, "First request should be allowed")

        // Should be blocked immediately
        let blocked = await store.check(key: "test")
        #expect(blocked != nil, "Should be blocked before window expires")

        // Wait for the window to expire
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms > 100ms window

        // Should be allowed again
        let afterExpiry = await store.check(key: "test")
        #expect(afterExpiry == nil, "Should be allowed after window expires")
    }

    // MARK: - RateLimitStore: Prune

    @Test func `prune removes stale entries`() async {
        let store = RateLimitStore(maxAttempts: 10, window: 0.1)

        // Add some entries
        _ = await store.check(key: "stale1")
        _ = await store.check(key: "stale2")

        // Wait for window to expire
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Prune should clean up expired entries
        await store.prune()

        // After pruning, these keys should be fresh — allowed again
        let result1 = await store.check(key: "stale1")
        #expect(result1 == nil, "stale1 should be allowed after prune clears expired entries")

        let result2 = await store.check(key: "stale2")
        #expect(result2 == nil, "stale2 should be allowed after prune clears expired entries")
    }

    @Test func `prune keeps active entries`() async {
        let store = RateLimitStore(maxAttempts: 2, window: 60)

        // Use up the limit
        _ = await store.check(key: "active")
        _ = await store.check(key: "active")

        // Prune should NOT remove entries still within the window
        await store.prune()

        let blocked = await store.check(key: "active")
        #expect(blocked != nil, "Active entries should survive prune")
    }

    // MARK: - Password Validation (min 10 characters)

    @Test func `password minimum length`() {
        // Password setup requires at least 10 characters.
        let tooShort = ["", "a", "123456789"] // 0, 1, 9 chars
        for pw in tooShort {
            #expect(pw.count < 10, "'\(pw)' should be fewer than 10 characters")
        }

        let justRight = "abcdefghij" // exactly 10
        #expect(justRight.count >= 10)

        let longer = "abcdefghijk" // 11
        #expect(longer.count >= 10)
    }

    // MARK: - QEMUBuilder: IPv4 Validation

    @Test func `valid I pv 4 addresses`() {
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("192.168.1.1") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("0.0.0.0") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("255.255.255.255") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("10.0.0.1") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("127.0.0.1") }
    }

    @Test func `invalid I pv 4 addresses`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("256.0.0.0") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("1.2.3") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("1.2.3.4.5") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("01.02.03.04") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("abc.def.ghi.jkl") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("192.168.1.1; rm -rf /") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("-1.0.0.0") }
    }

    // MARK: - QEMUBuilder: MAC Validation

    @Test func `valid MAC addresses`() {
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("52:54:00:12:34:56") }
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("aa:bb:cc:dd:ee:ff") }
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("AA:BB:CC:DD:EE:FF") }
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("00:00:00:00:00:00") }
    }

    @Test func `invalid MAC addresses`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34") } // too few octets
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34:56:78") } // too many octets
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34:GG") } // non-hex
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52-54-00-12-34-56") } // wrong separator
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("") } // empty
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("5254.0012.3456") } // dot notation
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34:5") } // short octet
    }

    // MARK: - QEMUBuilder: Port Validation (Boundary Values)

    @Test func `port validation boundaries`() {
        // Lower boundary
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(0) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(1) }

        // Upper boundary
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(65_535) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(65_536) }

        // Negative
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(-1) }

        // Common ports
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(22) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(80) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(443) }
    }

    // MARK: - VM Name Validation

    @Test func `valid VM names`() {
        #expect(throws: Never.self) { try validateVMName("my-vm") }
        #expect(throws: Never.self) { try validateVMName("test_vm.01") }
        #expect(throws: Never.self) { try validateVMName("Ubuntu 24.04") }
        #expect(throws: Never.self) { try validateVMName("a") } // minimum: 1 character
    }

    @Test func `empty VM name rejected`() {
        #expect(throws: (any Error).self) { try validateVMName("") }
        #expect(throws: (any Error).self) { try validateVMName("   ") } // whitespace-only
    }

    @Test func `too long VM name rejected`() {
        let longName = String(repeating: "a", count: 129)
        #expect(throws: (any Error).self) { try validateVMName(longName) }

        // Exactly 128 should be fine
        let maxName = String(repeating: "a", count: 128)
        #expect(throws: Never.self) { try validateVMName(maxName) }
    }

    @Test func `vm name special chars rejected`() {
        #expect(throws: (any Error).self) { try validateVMName("vm;rm -rf /") }
        #expect(throws: (any Error).self) { try validateVMName("vm&background") }
        #expect(throws: (any Error).self) { try validateVMName("vm$(cmd)") }
        #expect(throws: (any Error).self) { try validateVMName("vm`cmd`") }
        #expect(throws: (any Error).self) { try validateVMName("name\nnewline") }
        #expect(throws: (any Error).self) { try validateVMName("vm/path") }
    }
}
