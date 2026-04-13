import Foundation
import Testing
@testable import BarkVisorCore

struct ValidationTests {
    // MARK: - validateVMName

    @Test func `valid VM names`() {
        #expect(throws: Never.self) { try validateVMName("my-vm") }
        #expect(throws: Never.self) { try validateVMName("test_vm.01") }
        #expect(throws: Never.self) { try validateVMName("Ubuntu 24.04") }
        #expect(throws: Never.self) { try validateVMName("a") }
        #expect(throws: Never.self) { try validateVMName(String(repeating: "a", count: 128)) }
    }

    @Test func `empty VM name rejected`() {
        #expect(throws: (any Error).self) { try validateVMName("") }
        #expect(throws: (any Error).self) { try validateVMName("   ") }
    }

    @Test func `too long VM name rejected`() {
        #expect(throws: (any Error).self) { try validateVMName(String(repeating: "a", count: 129)) }
    }

    @Test func `vm name shell injection rejected`() {
        #expect(throws: (any Error).self) { try validateVMName("vm;rm -rf /") }
        #expect(throws: (any Error).self) { try validateVMName("vm&background") }
        #expect(throws: (any Error).self) { try validateVMName("vm$(cmd)") }
        #expect(throws: (any Error).self) { try validateVMName("vm`cmd`") }
        #expect(throws: (any Error).self) { try validateVMName("name\nnewline") }
        #expect(throws: (any Error).self) { try validateVMName("vm/path") }
    }

    // MARK: - validateBridgeName

    @Test func `valid bridge names`() {
        #expect(throws: Never.self) { try validateBridgeName("en0") }
        #expect(throws: Never.self) { try validateBridgeName("bridge0") }
        #expect(throws: Never.self) { try validateBridgeName("lo0") }
        #expect(throws: Never.self) { try validateBridgeName(String(repeating: "a", count: 15)) }
    }

    @Test func `bridge name too long`() {
        #expect(throws: (any Error).self) { try validateBridgeName(String(repeating: "a", count: 16)) }
    }

    @Test func `bridge name rejects special chars`() {
        #expect(throws: (any Error).self) { try validateBridgeName("en0; rm -rf /") }
        #expect(throws: (any Error).self) { try validateBridgeName("br-0") }
        #expect(throws: (any Error).self) { try validateBridgeName("br_0") }
        #expect(throws: (any Error).self) { try validateBridgeName("br.0") }
        #expect(throws: (any Error).self) { try validateBridgeName("br 0") }
    }

    // MARK: - validateDNS

    @Test func `valid DNS`() {
        #expect(throws: Never.self) { try validateDNS("8.8.8.8") }
        #expect(throws: Never.self) { try validateDNS("192.168.1.1") }
        #expect(throws: Never.self) { try validateDNS("0.0.0.0") }
        #expect(throws: Never.self) { try validateDNS("255.255.255.255") }
    }

    @Test func `invalid DNS`() {
        #expect(throws: (any Error).self) { try validateDNS("256.0.0.0") }
        #expect(throws: (any Error).self) { try validateDNS("1.2.3") }
        #expect(throws: (any Error).self) { try validateDNS("1.2.3.4.5") }
        #expect(throws: (any Error).self) { try validateDNS("abc") }
        #expect(throws: (any Error).self) { try validateDNS("") }
        #expect(throws: (any Error).self) { try validateDNS("01.02.03.04") }
    }

    // MARK: - validateMAC

    @Test func `valid MAC`() {
        #expect(throws: Never.self) { try validateMAC("52:54:00:12:34:56") }
        #expect(throws: Never.self) { try validateMAC("aa:bb:cc:dd:ee:ff") }
        #expect(throws: Never.self) { try validateMAC("AA:BB:CC:DD:EE:FF") }
    }

    @Test func `invalid MAC`() {
        #expect(throws: (any Error).self) { try validateMAC("52:54:00:12:34") }
        #expect(throws: (any Error).self) { try validateMAC("52:54:00:12:34:56:78") }
        #expect(throws: (any Error).self) { try validateMAC("52:54:00:12:34:GG") }
        #expect(throws: (any Error).self) { try validateMAC("52-54-00-12-34-56") }
        #expect(throws: (any Error).self) { try validateMAC("") }
    }
}
