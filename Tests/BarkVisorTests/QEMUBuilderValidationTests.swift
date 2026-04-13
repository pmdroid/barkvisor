import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite struct QEMUBuilderValidationTests {
    // MARK: - IPv4 Validation

    @Test func validIPv4() {
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("192.168.1.1") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("0.0.0.0") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("255.255.255.255") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("10.0.0.1") }
        #expect(throws: Never.self) { try QEMUBuilder.validateIPv4("172.16.0.1") }
    }

    @Test func invalidIPv4() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("256.0.0.0") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("1.2.3") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("1.2.3.4.5") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("01.02.03.04") } // leading zeros
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("abc.def.ghi.jkl") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateIPv4("") }
    }

    // MARK: - Port Validation

    @Test func validPort() {
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(1) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(80) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(443) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(65_535) }
    }

    @Test func invalidPort() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(0) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(-1) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(65_536) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(100_000) }
    }

    // MARK: - Protocol Validation

    @Test func validProtocol() {
        #expect(throws: Never.self) { try QEMUBuilder.validateProtocol("tcp") }
        #expect(throws: Never.self) { try QEMUBuilder.validateProtocol("udp") }
    }

    @Test func invalidProtocol() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("icmp") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("TCP") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("http") }
    }

    // MARK: - Resolution Validation

    @Test func validResolution() throws {
        let (w, h) = try QEMUBuilder.validateResolution("1280x800")
        #expect(w == "1280")
        #expect(h == "800")

        let (w2, h2) = try QEMUBuilder.validateResolution("1920x1080")
        #expect(w2 == "1920")
        #expect(h2 == "1080")

        let (w3, h3) = try QEMUBuilder.validateResolution("7680x4320")
        #expect(w3 == "7680")
        #expect(h3 == "4320")
    }

    @Test func invalidResolution() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("0x0") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("9999x9999") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("abc") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("1280x") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("x800") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("") }
    }

    // MARK: - MAC Address Validation

    @Test func validMAC() {
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("52:54:00:12:34:56") }
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("aa:bb:cc:dd:ee:ff") }
        #expect(throws: Never.self) { try QEMUBuilder.validateMAC("AA:BB:CC:DD:EE:FF") }
    }

    @Test func invalidMAC() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34") } // too few
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34:56:78") } // too many
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52:54:00:12:34:GG") } // non-hex
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("52-54-00-12-34-56") } // wrong separator
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("") } // empty
        #expect(throws: (any Error).self) { try QEMUBuilder.validateMAC("5254.0012.3456") } // dot notation
    }

    // MARK: - Shared Path Validation

    @Test func sharedPathRejectsCommas() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateSharedPath("/Users/test/path,with,commas") }
    }

    @Test func sharedPathRejectsOutsideAllowedPrefixes() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateSharedPath("/etc/passwd") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateSharedPath("/tmp/something") }
    }

    @Test func sharedPathRejectsNonExistentPath() {
        #expect(throws: (any Error).self) {
            try QEMUBuilder.validateSharedPath(
                NSHomeDirectory() + "/nonexistent_path_\(UUID().uuidString)",
            )
        }
    }

    @Test func sharedPathAcceptsHomeDirectory() {
        // Home directory itself should be valid (it exists and is within allowed prefix)
        #expect(throws: Never.self) { try QEMUBuilder.validateSharedPath(NSHomeDirectory()) }
    }

    // MARK: - VM Type

    @Test func unknownVMTypeThrows() {
        #expect(throws: (any Error).self) { try QEMUBuilder.binary(for: "linux-x86_64") }
        #expect(throws: (any Error).self) { try QEMUBuilder.binary(for: "freebsd") }
        #expect(throws: (any Error).self) { try QEMUBuilder.binary(for: "") }
    }
}
