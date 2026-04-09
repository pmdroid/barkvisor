import XCTest
@testable import BarkVisorCore

final class ValidationTests: XCTestCase {
    // MARK: - validateVMName

    func testValidVMNames() throws {
        XCTAssertNoThrow(try validateVMName("my-vm"))
        XCTAssertNoThrow(try validateVMName("test_vm.01"))
        XCTAssertNoThrow(try validateVMName("Ubuntu 24.04"))
        XCTAssertNoThrow(try validateVMName("a"))
        XCTAssertNoThrow(try validateVMName(String(repeating: "a", count: 128)))
    }

    func testEmptyVMNameRejected() {
        XCTAssertThrowsError(try validateVMName(""))
        XCTAssertThrowsError(try validateVMName("   "))
    }

    func testTooLongVMNameRejected() {
        XCTAssertThrowsError(try validateVMName(String(repeating: "a", count: 129)))
    }

    func testVMNameShellInjectionRejected() {
        XCTAssertThrowsError(try validateVMName("vm;rm -rf /"))
        XCTAssertThrowsError(try validateVMName("vm&background"))
        XCTAssertThrowsError(try validateVMName("vm$(cmd)"))
        XCTAssertThrowsError(try validateVMName("vm`cmd`"))
        XCTAssertThrowsError(try validateVMName("name\nnewline"))
        XCTAssertThrowsError(try validateVMName("vm/path"))
    }

    // MARK: - validateBridgeName

    func testValidBridgeNames() throws {
        XCTAssertNoThrow(try validateBridgeName("en0"))
        XCTAssertNoThrow(try validateBridgeName("bridge0"))
        XCTAssertNoThrow(try validateBridgeName("lo0"))
        XCTAssertNoThrow(try validateBridgeName(String(repeating: "a", count: 15)))
    }

    func testBridgeNameTooLong() {
        XCTAssertThrowsError(try validateBridgeName(String(repeating: "a", count: 16)))
    }

    func testBridgeNameRejectsSpecialChars() {
        XCTAssertThrowsError(try validateBridgeName("en0; rm -rf /"))
        XCTAssertThrowsError(try validateBridgeName("br-0"))
        XCTAssertThrowsError(try validateBridgeName("br_0"))
        XCTAssertThrowsError(try validateBridgeName("br.0"))
        XCTAssertThrowsError(try validateBridgeName("br 0"))
    }

    // MARK: - validateDNS

    func testValidDNS() throws {
        XCTAssertNoThrow(try validateDNS("8.8.8.8"))
        XCTAssertNoThrow(try validateDNS("192.168.1.1"))
        XCTAssertNoThrow(try validateDNS("0.0.0.0"))
        XCTAssertNoThrow(try validateDNS("255.255.255.255"))
    }

    func testInvalidDNS() {
        XCTAssertThrowsError(try validateDNS("256.0.0.0"))
        XCTAssertThrowsError(try validateDNS("1.2.3"))
        XCTAssertThrowsError(try validateDNS("1.2.3.4.5"))
        XCTAssertThrowsError(try validateDNS("abc"))
        XCTAssertThrowsError(try validateDNS(""))
        XCTAssertThrowsError(try validateDNS("01.02.03.04"))
    }

    // MARK: - validateMAC

    func testValidMAC() throws {
        XCTAssertNoThrow(try validateMAC("52:54:00:12:34:56"))
        XCTAssertNoThrow(try validateMAC("aa:bb:cc:dd:ee:ff"))
        XCTAssertNoThrow(try validateMAC("AA:BB:CC:DD:EE:FF"))
    }

    func testInvalidMAC() {
        XCTAssertThrowsError(try validateMAC("52:54:00:12:34"))
        XCTAssertThrowsError(try validateMAC("52:54:00:12:34:56:78"))
        XCTAssertThrowsError(try validateMAC("52:54:00:12:34:GG"))
        XCTAssertThrowsError(try validateMAC("52-54-00-12-34-56"))
        XCTAssertThrowsError(try validateMAC(""))
    }
}
