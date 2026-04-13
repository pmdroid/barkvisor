import Foundation
import Testing
@testable import BarkVisorCore

struct HostInfoServiceTests {
    @Test func `list interfaces returns at least loopback`() {
        let interfaces = HostInfoService.listInterfaces()
        // On any macOS host, we should get at least lo0
        #expect(!interfaces.isEmpty, "Should find at least one network interface")

        let lo = interfaces.first(where: { $0.name == "lo0" })
        #expect(lo != nil, "Should find loopback interface")
        #expect(lo?.ipAddress == "127.0.0.1")
    }

    @Test func `list interfaces has valid format`() {
        let interfaces = HostInfoService.listInterfaces()
        for iface in interfaces {
            #expect(!iface.name.isEmpty, "Interface name should not be empty")
            #expect(!iface.ipAddress.isEmpty, "IP address should not be empty")
            // Basic IP format check
            let parts = iface.ipAddress.split(separator: ".")
            #expect(parts.count == 4, "IP should have 4 octets: \(iface.ipAddress)")
        }
    }

    @Test func `interface exists for loopback`() {
        #expect(HostInfoService.interfaceExists("lo0"), "lo0 should always exist on macOS")
    }

    @Test func `interface exists for non existent`() {
        #expect(!HostInfoService.interfaceExists("fake_interface_999"))
    }
}
