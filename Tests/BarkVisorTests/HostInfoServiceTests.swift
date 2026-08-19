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

    @Test func `list interface addresses keeps IPv4 and does not leak zone ids`() {
        let addrs = HostInfoService.listInterfaceAddresses()
        #expect(!addrs.isEmpty, "Should find at least one address")
        let ipv4 = addrs.filter { !$0.ipAddress.contains(":") }
        #expect(!ipv4.isEmpty, "Should find at least one IPv4 address")
        for iface in ipv4 {
            #expect(
                iface.ipAddress.split(separator: ".").count == 4,
                "IPv4 should have 4 octets: \(iface.ipAddress)",
            )
        }
        for iface in addrs where iface.ipAddress.contains(":") {
            #expect(!iface.ipAddress.contains("%"), "IPv6 should drop the zone id: \(iface.ipAddress)")
            #expect(!iface.ipAddress.isEmpty)
        }
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
        #expect(!HostInfoService.interfaceExists(""))
        #expect(!HostInfoService.interfaceExists("../etc"))
    }

    @Test func `interface exists includes interfaces without requiring listInterfaces membership`() {
        // listInterfaces is IPv4-only; existence must still be true for loopback
        // even when we only care about the name probe (down/no-IP policy).
        #expect(HostInfoService.interfaceExists(Self.loopbackName))
        let listed = Set(HostInfoService.listInterfaces().map(\.name))
        #expect(listed.contains(Self.loopbackName))
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

    #if os(Linux)
        @Test func `listInterfaceSnapshots can include bridges without IPv4`() {
            // When sysfs has bridge devices not present in the IPv4 listInterfaces()
            // result, snapshots must still surface them (empty ipAddress).
            let ipv4Names = Set(HostInfoService.listInterfaces().map(\.name))
            let snaps = HostInfoService.listInterfaceSnapshots()
            let snapNames = Set(snaps.map(\.name))
            #expect(snapNames.isSuperset(of: ipv4Names))

            let bridges = LinuxHostNetwork.listBridgeInterfaces()
            for br in bridges {
                #expect(snapNames.contains(br), "snapshot list should include bridge \(br)")
                if !ipv4Names.contains(br) {
                    let snap = snaps.first(where: { $0.name == br })
                    #expect(snap?.ipAddress == "")
                }
            }
        }
    #endif
}
