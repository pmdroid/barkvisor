import Foundation
import Testing
@testable import BarkVisorCore

struct HostInfoServiceTests {
    /// Loopback iface name: `lo0` on macOS/BSD, `lo` on Linux.
    private static var loopbackName: String {
        #if os(Linux)
            "lo"
        #else
            "lo0"
        #endif
    }

    @Test func `list interfaces returns at least loopback`() {
        let interfaces = HostInfoService.listInterfaces()
        #expect(!interfaces.isEmpty, "Should find at least one network interface")

        let lo = interfaces.first(where: { $0.name == Self.loopbackName })
        #expect(lo != nil, "Should find loopback interface \(Self.loopbackName)")
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
        #expect(
            HostInfoService.interfaceExists(Self.loopbackName),
            "\(Self.loopbackName) should exist on this host",
        )
    }

    @Test func `interface exists for non existent`() {
        #expect(!HostInfoService.interfaceExists("fake_interface_999"))
    }

    @Test func `displayName labels loopback and common interfaces`() {
        #if os(Linux)
            #expect(HostInfoService.displayName(for: "lo") == "lo (Loopback)")
            #expect(HostInfoService.displayName(for: "br0") == "br0 (Bridge)")
            #expect(HostInfoService.displayName(for: "docker0") == "docker0 (Container)")
            #expect(HostInfoService.displayName(for: "eth0") == "eth0 (Ethernet)")
            #expect(HostInfoService.displayName(for: "ens3") == "ens3 (Ethernet)")
        #else
            #expect(HostInfoService.displayName(for: "lo0") == "lo0 (Loopback)")
            #expect(HostInfoService.displayName(for: "en0") == "en0 (Ethernet/Wi-Fi)")
            #expect(HostInfoService.displayName(for: "bridge0") == "bridge0 (Bridge)")
        #endif
    }

    @Test func `apiBridgeStatus hides not_configured`() {
        #expect(HostInfoService.apiBridgeStatus(nil) == nil)
        #expect(HostInfoService.apiBridgeStatus("not_configured") == nil)
        #expect(HostInfoService.apiBridgeStatus("active") == "active")
        #expect(HostInfoService.apiBridgeStatus("installed") == "installed")
    }

    @Test func `listInterfaceSnapshots includes display names`() {
        let snaps = HostInfoService.listInterfaceSnapshots()
        #expect(!snaps.isEmpty)
        let lo = snaps.first(where: { $0.name == Self.loopbackName })
        #expect(lo != nil)
        #expect(lo?.displayName.contains("Loopback") == true)
        #expect(lo?.bridgeStatus == nil)
    }
}
