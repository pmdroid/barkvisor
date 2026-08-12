import Foundation
import Testing
@testable import BarkVisorCore

struct LinuxBridgeUSBTests {
    @Test func `capabilities enable bridge and usb on supported hosts`() {
        #if os(Linux) || os(macOS)
            #expect(PlatformCapabilities.supportsBridgedNetworking)
            #expect(PlatformCapabilities.supportsUSBPassthrough)
        #endif
        #if os(Linux)
            // Linux uses host bridges + QEMU -netdev bridge — not a managed daemon.
            #expect(!PlatformCapabilities.supportsManagedBridgeDaemon)
            let err = #expect(throws: BarkVisorError.self) {
                try PlatformCapabilities.requireManagedBridgeDaemon()
            }
            #expect(err?.httpStatus == 422)
            #expect(err?.code == "managed_bridge_daemon")
        #elseif os(macOS)
            #expect(PlatformCapabilities.supportsManagedBridgeDaemon)
            #expect(throws: Never.self) {
                try PlatformCapabilities.requireManagedBridgeDaemon()
            }
        #endif
    }

    @Test func `parse lsusb line extracts vendor product and name`() {
        let line = "Bus 001 Device 004: ID 046d:c52b Logitech, Inc. Unifying Receiver"
        let dev = USBDeviceService.parseLsusbLine(line)
        #expect(dev != nil)
        #expect(dev?.vendorId == "0x046d")
        #expect(dev?.productId == "0xc52b")
        #expect(dev?.name.contains("Logitech") == true)
    }

    @Test func `parse lsusb skips root hubs`() {
        let line = "Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub"
        #expect(USBDeviceService.parseLsusbLine(line) == nil)
    }

    @Test func `parse lsusb rejects garbage`() {
        #expect(USBDeviceService.parseLsusbLine("not a device line") == nil)
    }

    @Test func `bridge interface names validate`() throws {
        try validateBridgeName("br0")
        try validateBridgeName("virbr0")
        try validateBridgeName("br-lan")
        try validateBridgeName("ovs-br0")
        let err = #expect(throws: BarkVisorError.self) {
            try validateBridgeName("bad-name!")
        }
        #expect(err?.httpStatus == 400)
    }

    @Test func `linux host network sysfs path is stable`() {
        #expect(LinuxHostNetwork.netClassPath == "/sys/class/net")
    }

    @Test func `interfaceExists agrees HostInfoService and LinuxHostNetwork on Linux`() {
        #if os(Linux)
            // Single existence policy: sysfs (down / no-IP still present).
            #expect(HostInfoService.interfaceExists("lo"))
            #expect(LinuxHostNetwork.interfaceExists("lo"))
            #expect(HostInfoService.interfaceExists("lo") == LinuxHostNetwork.interfaceExists("lo"))
            #expect(!HostInfoService.interfaceExists("fake_interface_999"))
            #expect(!LinuxHostNetwork.interfaceExists("fake_interface_999"))
            // Reject path-like names (no traversal into sysfs).
            #expect(!HostInfoService.interfaceExists("../etc"))
            #expect(!LinuxHostNetwork.interfaceExists("lo/../lo"))
            #expect(!HostInfoService.interfaceExists(""))
        #endif
    }

    @Test func `requireBridgeableInterface rejects missing iface`() {
        #if os(Linux)
            let err = #expect(throws: BarkVisorError.self) {
                try LinuxHostNetwork.requireBridgeableInterface("no_such_iface_xyz")
            }
            #expect(err?.httpStatus == 503 || err?.httpStatus == 400 || err?.httpStatus == 500)
        #endif
    }
}
