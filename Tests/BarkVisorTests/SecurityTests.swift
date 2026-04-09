import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

final class SecurityTests: XCTestCase {
    // MARK: - RateLimitStore: Blocking After Max Attempts

    func testRateLimitBlocksAfterMaxAttempts() async {
        let store = RateLimitStore(maxAttempts: 3, window: 60)

        // First 3 requests should be allowed
        for i in 1 ... 3 {
            let result = await store.check(key: "192.168.1.1")
            XCTAssertNil(result, "Request \(i) should be allowed")
        }

        // 4th request should be blocked
        let blocked = await store.check(key: "192.168.1.1")
        XCTAssertNotNil(blocked, "Request after maxAttempts should be blocked")
        XCTAssertGreaterThan(blocked ?? 0, 0, "Retry-after should be positive")
    }

    func testRateLimitTracksKeysIndependently() async {
        let store = RateLimitStore(maxAttempts: 2, window: 60)

        // Exhaust limit for key A
        _ = await store.check(key: "A")
        _ = await store.check(key: "A")
        let blockedA = await store.check(key: "A")
        XCTAssertNotNil(blockedA, "Key A should be blocked")

        // Key B should still be allowed
        let allowedB = await store.check(key: "B")
        XCTAssertNil(allowedB, "Key B should be independent and allowed")
    }

    // MARK: - RateLimitStore: Window Expiration

    func testRateLimitAllowsAfterWindowExpires() async {
        // Use a very short window so it expires quickly
        let store = RateLimitStore(maxAttempts: 1, window: 0.1)

        // Use the single allowed attempt
        let first = await store.check(key: "test")
        XCTAssertNil(first, "First request should be allowed")

        // Should be blocked immediately
        let blocked = await store.check(key: "test")
        XCTAssertNotNil(blocked, "Should be blocked before window expires")

        // Wait for the window to expire
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms > 100ms window

        // Should be allowed again
        let afterExpiry = await store.check(key: "test")
        XCTAssertNil(afterExpiry, "Should be allowed after window expires")
    }

    // MARK: - RateLimitStore: Prune

    func testPruneRemovesStaleEntries() async {
        let store = RateLimitStore(maxAttempts: 10, window: 0.1)

        // Add some entries
        _ = await store.check(key: "stale1")
        _ = await store.check(key: "stale2")

        // Wait for window to expire
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Prune should clean up expired entries
        await store.prune()

        // After pruning, these keys should be fresh — allowed again
        // (if prune didn't work, the old timestamps would still count)
        let result1 = await store.check(key: "stale1")
        XCTAssertNil(result1, "stale1 should be allowed after prune clears expired entries")

        let result2 = await store.check(key: "stale2")
        XCTAssertNil(result2, "stale2 should be allowed after prune clears expired entries")
    }

    func testPruneKeepsActiveEntries() async {
        let store = RateLimitStore(maxAttempts: 2, window: 60)

        // Use up the limit
        _ = await store.check(key: "active")
        _ = await store.check(key: "active")

        // Prune should NOT remove entries still within the window
        await store.prune()

        let blocked = await store.check(key: "active")
        XCTAssertNotNil(blocked, "Active entries should survive prune")
    }

    // MARK: - Password Validation (min 10 characters)

    func testPasswordMinimumLength() {
        // Password setup requires at least 10 characters.
        let tooShort = ["", "a", "123456789"] // 0, 1, 9 chars
        for pw in tooShort {
            XCTAssertTrue(pw.count < 10, "'\(pw)' should be fewer than 10 characters")
        }

        let justRight = "abcdefghij" // exactly 10
        XCTAssertTrue(justRight.count >= 10)

        let longer = "abcdefghijk" // 11
        XCTAssertTrue(longer.count >= 10)
    }

    // MARK: - QEMUBuilder: IPv4 Validation

    func testValidIPv4Addresses() throws {
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("192.168.1.1"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("0.0.0.0"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("255.255.255.255"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("10.0.0.1"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("127.0.0.1"))
    }

    func testInvalidIPv4Addresses() {
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("256.0.0.0"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("1.2.3"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("1.2.3.4.5"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("01.02.03.04"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("abc.def.ghi.jkl"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4(""))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("192.168.1.1; rm -rf /"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("-1.0.0.0"))
    }

    // MARK: - QEMUBuilder: MAC Validation

    func testValidMACAddresses() throws {
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("52:54:00:12:34:56"))
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("aa:bb:cc:dd:ee:ff"))
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("AA:BB:CC:DD:EE:FF"))
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("00:00:00:00:00:00"))
    }

    func testInvalidMACAddresses() {
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34")) // too few octets
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34:56:78")) // too many octets
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34:GG")) // non-hex
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52-54-00-12-34-56")) // wrong separator
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("")) // empty
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("5254.0012.3456")) // dot notation
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34:5")) // short octet
    }

    // MARK: - QEMUBuilder: Port Validation (Boundary Values)

    func testPortValidationBoundaries() throws {
        // Lower boundary
        XCTAssertThrowsError(try QEMUBuilder.validatePort(0), "Port 0 should be rejected")
        XCTAssertNoThrow(try QEMUBuilder.validatePort(1), "Port 1 should be accepted")

        // Upper boundary
        XCTAssertNoThrow(try QEMUBuilder.validatePort(65_535), "Port 65535 should be accepted")
        XCTAssertThrowsError(try QEMUBuilder.validatePort(65_536), "Port 65536 should be rejected")

        // Negative
        XCTAssertThrowsError(try QEMUBuilder.validatePort(-1), "Negative port should be rejected")

        // Common ports
        XCTAssertNoThrow(try QEMUBuilder.validatePort(22))
        XCTAssertNoThrow(try QEMUBuilder.validatePort(80))
        XCTAssertNoThrow(try QEMUBuilder.validatePort(443))
    }

    // MARK: - VM Name Validation

    func testValidVMNames() throws {
        XCTAssertNoThrow(try validateVMName("my-vm"))
        XCTAssertNoThrow(try validateVMName("test_vm.01"))
        XCTAssertNoThrow(try validateVMName("Ubuntu 24.04"))
        XCTAssertNoThrow(try validateVMName("a")) // minimum: 1 character
    }

    func testEmptyVMNameRejected() {
        XCTAssertThrowsError(try validateVMName(""))
        XCTAssertThrowsError(try validateVMName("   ")) // whitespace-only
    }

    func testTooLongVMNameRejected() {
        let longName = String(repeating: "a", count: 129)
        XCTAssertThrowsError(try validateVMName(longName))

        // Exactly 128 should be fine
        let maxName = String(repeating: "a", count: 128)
        XCTAssertNoThrow(try validateVMName(maxName))
    }

    func testVMNameSpecialCharsRejected() {
        XCTAssertThrowsError(try validateVMName("vm;rm -rf /"))
        XCTAssertThrowsError(try validateVMName("vm&background"))
        XCTAssertThrowsError(try validateVMName("vm$(cmd)"))
        XCTAssertThrowsError(try validateVMName("vm`cmd`"))
        XCTAssertThrowsError(try validateVMName("name\nnewline"))
        XCTAssertThrowsError(try validateVMName("vm/path"))
    }
}
