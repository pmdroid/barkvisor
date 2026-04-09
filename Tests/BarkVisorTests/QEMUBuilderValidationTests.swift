import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

final class QEMUBuilderValidationTests: XCTestCase {
    // MARK: - IPv4 Validation

    func testValidIPv4() throws {
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("192.168.1.1"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("0.0.0.0"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("255.255.255.255"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("10.0.0.1"))
        XCTAssertNoThrow(try QEMUBuilder.validateIPv4("172.16.0.1"))
    }

    func testInvalidIPv4() {
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("256.0.0.0"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("1.2.3"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("1.2.3.4.5"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("01.02.03.04")) // leading zeros
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4("abc.def.ghi.jkl"))
        XCTAssertThrowsError(try QEMUBuilder.validateIPv4(""))
    }

    // MARK: - Port Validation

    func testValidPort() throws {
        XCTAssertNoThrow(try QEMUBuilder.validatePort(1))
        XCTAssertNoThrow(try QEMUBuilder.validatePort(80))
        XCTAssertNoThrow(try QEMUBuilder.validatePort(443))
        XCTAssertNoThrow(try QEMUBuilder.validatePort(65_535))
    }

    func testInvalidPort() {
        XCTAssertThrowsError(try QEMUBuilder.validatePort(0))
        XCTAssertThrowsError(try QEMUBuilder.validatePort(-1))
        XCTAssertThrowsError(try QEMUBuilder.validatePort(65_536))
        XCTAssertThrowsError(try QEMUBuilder.validatePort(100_000))
    }

    // MARK: - Protocol Validation

    func testValidProtocol() throws {
        XCTAssertNoThrow(try QEMUBuilder.validateProtocol("tcp"))
        XCTAssertNoThrow(try QEMUBuilder.validateProtocol("udp"))
    }

    func testInvalidProtocol() {
        XCTAssertThrowsError(try QEMUBuilder.validateProtocol("icmp"))
        XCTAssertThrowsError(try QEMUBuilder.validateProtocol("TCP"))
        XCTAssertThrowsError(try QEMUBuilder.validateProtocol(""))
        XCTAssertThrowsError(try QEMUBuilder.validateProtocol("http"))
    }

    // MARK: - Resolution Validation

    func testValidResolution() throws {
        let (w, h) = try QEMUBuilder.validateResolution("1280x800")
        XCTAssertEqual(w, "1280")
        XCTAssertEqual(h, "800")

        let (w2, h2) = try QEMUBuilder.validateResolution("1920x1080")
        XCTAssertEqual(w2, "1920")
        XCTAssertEqual(h2, "1080")

        let (w3, h3) = try QEMUBuilder.validateResolution("7680x4320")
        XCTAssertEqual(w3, "7680")
        XCTAssertEqual(h3, "4320")
    }

    func testInvalidResolution() {
        XCTAssertThrowsError(try QEMUBuilder.validateResolution("0x0"))
        XCTAssertThrowsError(try QEMUBuilder.validateResolution("9999x9999"))
        XCTAssertThrowsError(try QEMUBuilder.validateResolution("abc"))
        XCTAssertThrowsError(try QEMUBuilder.validateResolution("1280x"))
        XCTAssertThrowsError(try QEMUBuilder.validateResolution("x800"))
        XCTAssertThrowsError(try QEMUBuilder.validateResolution(""))
    }

    // MARK: - MAC Address Validation

    func testValidMAC() throws {
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("52:54:00:12:34:56"))
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("aa:bb:cc:dd:ee:ff"))
        XCTAssertNoThrow(try QEMUBuilder.validateMAC("AA:BB:CC:DD:EE:FF"))
    }

    func testInvalidMAC() {
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34")) // too few
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34:56:78")) // too many
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52:54:00:12:34:GG")) // non-hex
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("52-54-00-12-34-56")) // wrong separator
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("")) // empty
        XCTAssertThrowsError(try QEMUBuilder.validateMAC("5254.0012.3456")) // dot notation
    }

    // MARK: - Shared Path Validation

    func testSharedPathRejectsCommas() {
        XCTAssertThrowsError(try QEMUBuilder.validateSharedPath("/Users/test/path,with,commas"))
    }

    func testSharedPathRejectsOutsideAllowedPrefixes() {
        XCTAssertThrowsError(try QEMUBuilder.validateSharedPath("/etc/passwd"))
        XCTAssertThrowsError(try QEMUBuilder.validateSharedPath("/tmp/something"))
    }

    func testSharedPathRejectsNonExistentPath() {
        XCTAssertThrowsError(
            try QEMUBuilder.validateSharedPath(
                NSHomeDirectory() + "/nonexistent_path_\(UUID().uuidString)",
            ),
        )
    }

    func testSharedPathAcceptsHomeDirectory() throws {
        // Home directory itself should be valid (it exists and is within allowed prefix)
        XCTAssertNoThrow(try QEMUBuilder.validateSharedPath(NSHomeDirectory()))
    }

    // MARK: - VM Type

    func testUnknownVMTypeThrows() {
        XCTAssertThrowsError(try QEMUBuilder.binary(for: "linux-x86_64"))
        XCTAssertThrowsError(try QEMUBuilder.binary(for: "freebsd"))
        XCTAssertThrowsError(try QEMUBuilder.binary(for: ""))
    }
}
