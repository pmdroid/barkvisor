import Foundation
import Testing
@testable import BarkVisorCore

struct GuestAddressingTests {
    @Test func `dhcp is the default and writes no network-config`() throws {
        let dhcp = GuestAddressing.dhcp
        #expect(dhcp.isDHCP)
        #expect(try dhcp.networkConfigYAML(macAddress: "52:54:00:12:34:56") == nil)
        #expect(GuestAddressing.composeInstanceID(base: "vm-1", addressing: nil) == "vm-1")
        #expect(GuestAddressing.composeInstanceID(base: "vm-1", addressing: dhcp) == "vm-1-net-dhcp")
    }

    @Test func `static writes nocloud v2 and bumps instance-id`() throws {
        let staticAddr = GuestAddressing(
            mode: "static",
            ipv4: "192.168.1.50",
            prefixLength: 24,
            gateway: "192.168.1.1",
            nameservers: ["1.1.1.1", "8.8.8.8"],
        )
        let yaml = try #require(try staticAddr.networkConfigYAML(macAddress: "52:54:00:AB:CD:EF"))
        #expect(yaml.contains("version: 2"))
        #expect(yaml.contains("dhcp4: false"))
        #expect(yaml.contains("192.168.1.50/24"))
        #expect(yaml.contains("via: 192.168.1.1"))
        #expect(yaml.contains("1.1.1.1"))
        #expect(yaml.contains("macaddress: \"52:54:00:ab:cd:ef\""))
        let first = GuestAddressing.composeInstanceID(base: "vm-1", addressing: staticAddr)
        #expect(first.hasPrefix("vm-1-net-s"))
        #expect(first != "vm-1")
        #expect(first != GuestAddressing.composeInstanceID(base: "vm-1", addressing: .dhcp))
        let changed = GuestAddressing(
            mode: "static",
            ipv4: "192.168.1.51",
            prefixLength: 24,
            gateway: "192.168.1.1",
            nameservers: ["1.1.1.1"],
        )
        #expect(
            GuestAddressing.composeInstanceID(base: "vm-1", addressing: staticAddr)
                != GuestAddressing.composeInstanceID(base: "vm-1", addressing: changed),
        )
    }

    @Test func `static is refused on NAT isolated and without cloud-init`() throws {
        let staticAddr = GuestAddressing(
            mode: "static", ipv4: "192.168.1.50", prefixLength: 24, gateway: "192.168.1.1",
        )
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing.require(staticAddr, networkMode: .nat, cloudInitApplies: true)
        }
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing.require(staticAddr, networkMode: .isolated, cloudInitApplies: true)
        }
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing.require(staticAddr, networkMode: .bridged, cloudInitApplies: false)
        }
        let allowed = try GuestAddressing.require(
            staticAddr, networkMode: .bridged, cloudInitApplies: true,
        )
        #expect(allowed?.isStatic == true)
    }

    @Test func `static fields are validated`() {
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing(mode: "static", ipv4: "nope", prefixLength: 24, gateway: "192.168.1.1")
                .validated()
        }
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing(
                mode: "static", ipv4: "192.168.1.50", prefixLength: 99, gateway: "192.168.1.1",
            ).validated()
        }
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing(mode: "static", ipv4: "192.168.1.50", prefixLength: 24, gateway: nil)
                .validated()
        }
        #expect(throws: BarkVisorError.self) {
            try GuestAddressing(mode: "foo").validated()
        }
    }

    @Test func `cloud-init applies when keys user-data or an existing ISO exist`() {
        #expect(
            GuestAddressing.cloudInitApplies(
                cloudImageId: "img", isoId: nil, sshKeys: ["ssh-ed25519 AAAA"], userData: nil,
            ),
        )
        #expect(
            GuestAddressing.cloudInitApplies(
                cloudImageId: "img", isoId: nil, sshKeys: [], userData: "packages:\n  - vim\n",
            ),
        )
        #expect(
            GuestAddressing.cloudInitApplies(
                cloudImageId: nil, isoId: "iso", sshKeys: [], userData: nil,
                existingCloudInitPath: "/data/cidata.iso",
            ),
        )
        #expect(
            GuestAddressing.cloudInitApplies(
                cloudImageId: "img", isoId: nil, sshKeys: [], userData: nil,
            ),
        )
        #expect(
            !GuestAddressing.cloudInitApplies(
                cloudImageId: nil, isoId: "iso", sshKeys: [], userData: nil,
            ),
        )
    }
}
