import Foundation
import Testing
@testable import BarkVisorCore

struct HostInterfaceAddressDiscoveryTests {
    @Test func `merge live addresses tags unknown IPs as alias`() {
        let config = HostInterfaceAddressing(
            addresses: [
                HostInterfaceAddressEntry(cidr: "192.168.1.10/24", source: .static, primary: true),
            ],
            dhcpEnabled: false,
            gateway: "192.168.1.1",
            dns: ["1.1.1.1"],
        )
        let merged = HostInterfaceAddressDiscovery.mergeLiveAddresses(
            config: config,
            liveIPv4: ["192.168.1.10", "10.0.0.2"],
        )
        #expect(merged.addresses.count == 2)
        #expect(merged.addresses[0].source == .static)
        #expect(merged.addresses[1].cidr == "10.0.0.2/32")
        #expect(merged.addresses[1].source == .alias)
    }

    @Test func `merge live addresses marks dhcp primary from live`() {
        let config = HostInterfaceAddressing(
            dhcpEnabled: true,
            gateway: "192.168.30.1",
            dns: ["1.1.1.1"],
        )
        let merged = HostInterfaceAddressDiscovery.mergeLiveAddresses(
            config: config,
            liveIPv4: ["192.168.30.50", "10.0.0.2"],
        )
        #expect(merged.addresses.count == 2)
        #expect(merged.addresses[0].source == .dhcp)
        #expect(merged.addresses[0].primary)
        #expect(merged.addresses[0].cidr == "192.168.30.50/32")
        #expect(merged.addresses[1].source == .alias)
    }

    @Test func `list interface addresses returns multiple IPv4 on same interface`() {
        let rows = [
            HostInterfaceInfo(name: "eth0", ipAddress: "192.168.1.10"),
            HostInterfaceInfo(name: "eth0", ipAddress: "10.0.0.2"),
            HostInterfaceInfo(name: "eth0", ipAddress: "fe80::1"),
        ]
        let merged = HostInterfaceAddressDiscovery.mergeLiveAddresses(
            config: HostInterfaceAddressing(),
            liveIPv4: rows.filter { !$0.ipAddress.contains(":") && $0.name == "eth0" }.map(\.ipAddress),
        )
        #expect(merged.addresses.count == 2)
        #expect(Set(merged.addresses.map { HostInterfaceAddressDiscovery.ipFromCIDR($0.cidr) }) == [
            "192.168.1.10", "10.0.0.2",
        ])
    }

    @Test func `prefix length from subnet mask`() {
        #expect(HostInterfaceAddressDiscovery.prefixLength(fromMask: "255.255.255.0") == 24)
        #expect(HostInterfaceAddressDiscovery.prefixLength(fromMask: "255.255.0.0") == 16)
    }

    #if os(macOS)
        @Test func `parse macOS getinfo dhcp fixture`() {
            let text = """
            DHCP Configuration
            IP address: 192.168.30.50
            Subnet mask: 255.255.255.0
            Router: 192.168.30.1
            """
            let parsed = MacHostInterfaceAddressRead.parseGetInfo(text)
            #expect(parsed.dhcpEnabled)
            #expect(parsed.gateway == "192.168.30.1")
            #expect(parsed.staticCIDR == nil)
        }

        @Test func `parse macOS getinfo manual fixture`() {
            let text = """
            Manual Configuration
            IP address: 192.168.1.10
            Subnet mask: 255.255.255.0
            Router: 192.168.1.1
            """
            let parsed = MacHostInterfaceAddressRead.parseGetInfo(text)
            #expect(!parsed.dhcpEnabled)
            #expect(parsed.staticCIDR == "192.168.1.10/24")
            #expect(parsed.gateway == "192.168.1.1")
        }

        @Test func `parse macOS additional addresses fixture`() {
            let text = """
            Additional IPv4 Address: 10.0.0.2
            Subnet mask: 255.255.255.0
            """
            #expect(MacHostInterfaceAddressRead.parseAdditionalAddresses(text) == ["10.0.0.2/24"])
        }

        @Test func `macOS dhcp plus alias addressing fixture`() {
            let info = """
            DHCP Configuration
            IP address: 192.168.30.50
            Subnet mask: 255.255.255.0
            Router: 192.168.30.1
            """
            let parsed = MacHostInterfaceAddressRead.parseGetInfo(info)
            var config = MacHostInterfaceAddressRead.buildAddressing(
                parsed: parsed,
                additionalCIDRs: ["10.0.0.2/24"],
                dns: ["1.1.1.1"],
                managedByBarkvisor: false,
            )
            config = HostInterfaceAddressDiscovery.mergeLiveAddresses(
                config: config,
                liveIPv4: ["192.168.30.50", "10.0.0.2"],
            )
            #expect(config.dhcpEnabled)
            #expect(config.gateway == "192.168.30.1")
            #expect(config.dns == ["1.1.1.1"])
            #expect(config.addresses.count == 2)
            #expect(config.addresses[0].source == .dhcp)
            #expect(config.addresses[1].source == .alias)
        }
    #endif

    @Test func `parse netplan multi address dhcp fixture`() {
        let yaml = """
        # managed-by: barkvisor
        network:
          version: 2
          renderer: networkd
          ethernets:
            eth0:
              dhcp4: false
          bridges:
            br0:
              interfaces: [eth0]
              dhcp4: true
              addresses: [192.168.1.10/24, 10.0.0.2/24]
              routes:
                - to: default
                  via: 192.168.1.1
              nameservers:
                addresses: [1.1.1.1]
        """
        let parsed = LinuxHostInterfaceAddressRead.parseNetplan(yaml, interface: "br0")
        #expect(parsed != nil)
        #expect(parsed?.dhcpEnabled == true)
        #expect(parsed?.gateway == "192.168.1.1")
        #expect(parsed?.dns == ["1.1.1.1"])
        #expect(parsed?.managedByBarkvisor == true)
        #expect(parsed?.addresses.count == 2)
        #expect(parsed?.addresses.map(\.cidr) == ["192.168.1.10/24", "10.0.0.2/24"])
    }

    @Test func `parse netplan unknown interface is not managed`() {
        let yaml = """
        # managed-by: barkvisor
        network:
          version: 2
          bridges:
            br0:
              dhcp4: true
        """
        #expect(LinuxHostInterfaceAddressRead.parseNetplan(yaml, interface: "docker0") == nil)
        let br0 = LinuxHostInterfaceAddressRead.parseNetplan(yaml, interface: "br0")
        #expect(br0?.managedByBarkvisor == true)
    }

    @Test func `nmcli parse leaves managedByBarkvisor false`() {
        let text = """
        IP4.ADDRESS[1]:192.168.30.50/24
        IP4.GATEWAY:192.168.30.1
        IP4.METHOD:auto
        """
        #expect(LinuxHostInterfaceAddressRead.parseNmcliDeviceShow(text).managedByBarkvisor == false)
    }

    @Test func `parse nmcli device show fixture`() {
        let text = """
        IP4.ADDRESS[1]:192.168.30.50/24
        IP4.GATEWAY:192.168.30.1
        IP4.DNS[1]:1.1.1.1
        IP4.METHOD:auto
        """
        let parsed = LinuxHostInterfaceAddressRead.parseNmcliDeviceShow(text)
        #expect(parsed.dhcpEnabled)
        #expect(parsed.gateway == "192.168.30.1")
        #expect(parsed.dns == ["1.1.1.1"])
        #expect(parsed.addresses.count == 1)
        #expect(parsed.addresses[0].source == .dhcp)
    }

    @Test func `listInterfaceSnapshots includes addressing fields`() {
        let addressing: [String: HostInterfaceAddressing] = [
            Self.loopbackName: HostInterfaceAddressing(
                addresses: [
                    HostInterfaceAddressEntry(cidr: "127.0.0.1/8", source: .static, primary: true),
                ],
                dhcpEnabled: false,
            ),
        ]
        let snaps = HostInfoService.listInterfaceSnapshots(addressingByInterface: addressing)
        let lo = snaps.first(where: { $0.name == Self.loopbackName })
        #expect(lo != nil)
        #expect(lo?.addresses.count == 1)
        #expect(lo?.addresses[0].cidr == "127.0.0.1/8")
        #expect(lo?.dhcpEnabled == false)
    }

    /// Loopback iface name: `lo0` on macOS/BSD, `lo` on Linux.
    private static var loopbackName: String {
        #if os(Linux)
            "lo"
        #else
            "lo0"
        #endif
    }
}
