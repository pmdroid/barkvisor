import XCTest
@testable import BarkVisorCore

final class HostInfoServiceTests: XCTestCase {
    func testListInterfacesReturnsAtLeastLoopback() {
        let interfaces = HostInfoService.listInterfaces()
        // On any macOS host, we should get at least lo0
        XCTAssertFalse(interfaces.isEmpty, "Should find at least one network interface")

        let lo = interfaces.first(where: { $0.name == "lo0" })
        XCTAssertNotNil(lo, "Should find loopback interface")
        XCTAssertEqual(lo?.ipAddress, "127.0.0.1")
    }

    func testListInterfacesHasValidFormat() {
        let interfaces = HostInfoService.listInterfaces()
        for iface in interfaces {
            XCTAssertFalse(iface.name.isEmpty, "Interface name should not be empty")
            XCTAssertFalse(iface.ipAddress.isEmpty, "IP address should not be empty")
            // Basic IP format check
            let parts = iface.ipAddress.split(separator: ".")
            XCTAssertEqual(parts.count, 4, "IP should have 4 octets: \(iface.ipAddress)")
        }
    }

    func testInterfaceExistsForLoopback() {
        XCTAssertTrue(HostInfoService.interfaceExists("lo0"), "lo0 should always exist on macOS")
    }

    func testInterfaceExistsForNonExistent() {
        XCTAssertFalse(HostInfoService.interfaceExists("fake_interface_999"))
    }
}
