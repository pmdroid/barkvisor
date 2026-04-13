import Foundation
import Testing
@testable import BarkVisorCore

struct MACAddressTests {
    @Test func `generate qemu MAC format`() {
        for _ in 0 ..< 100 {
            let mac = MACAddress.generateQemu()
            let parts = mac.split(separator: ":")
            #expect(parts.count == 6, "MAC should have 6 octets: \(mac)")
            #expect(String(parts[0]) == "52", "First octet should be 52")
            #expect(String(parts[1]) == "54", "Second octet should be 54")
            #expect(String(parts[2]) == "00", "Third octet should be 00")
            for part in parts {
                #expect(part.count == 2, "Each octet should be 2 chars: \(part)")
                // swiftformat:disable:next preferKeyPath
                #expect(part.allSatisfy { $0.isHexDigit }, "Each octet must be hex: \(part)")
            }
        }
    }

    @Test func `generate qemu MAC randomness`() {
        // Generate many MACs and check they aren't all the same
        let macs = (0 ..< 20).map { _ in MACAddress.generateQemu() }
        let uniqueMACs = Set(macs)
        #expect(uniqueMACs.count > 1, "MACs should be random, not all identical")
    }
}
