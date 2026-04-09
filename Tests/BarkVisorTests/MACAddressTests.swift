import XCTest
@testable import BarkVisorCore

final class MACAddressTests: XCTestCase {
    func testGenerateQemuMACFormat() {
        for _ in 0 ..< 100 {
            let mac = MACAddress.generateQemu()
            let parts = mac.split(separator: ":")
            XCTAssertEqual(parts.count, 6, "MAC should have 6 octets: \(mac)")
            XCTAssertEqual(String(parts[0]), "52", "First octet should be 52")
            XCTAssertEqual(String(parts[1]), "54", "Second octet should be 54")
            XCTAssertEqual(String(parts[2]), "00", "Third octet should be 00")
            for part in parts {
                XCTAssertEqual(part.count, 2, "Each octet should be 2 chars: \(part)")
                XCTAssertTrue(part.allSatisfy(\.isHexDigit), "Each octet must be hex: \(part)")
            }
        }
    }

    func testGenerateQemuMACRandomness() {
        // Generate many MACs and check they aren't all the same
        let macs = (0 ..< 20).map { _ in MACAddress.generateQemu() }
        let uniqueMACs = Set(macs)
        XCTAssertGreaterThan(uniqueMACs.count, 1, "MACs should be random, not all identical")
    }
}
