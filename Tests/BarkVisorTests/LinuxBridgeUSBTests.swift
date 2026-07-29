import Foundation
import Testing
@testable import BarkVisorCore

struct LinuxBridgeUSBTests {
    @Test func `capabilities enable bridge and usb on supported hosts`() {
        #if os(Linux) || os(macOS)
            #expect(PlatformCapabilities.supportsBridgedNetworking)
            #expect(PlatformCapabilities.supportsUSBPassthrough)
            #expect(PrivilegeService.isBridgedNetworkingSupported)
        #endif
        #if os(Linux)
            // Linux uses host bridges + QEMU -netdev bridge — not a managed daemon.
            #expect(!PlatformCapabilities.supportsManagedBridgeDaemon)
            #expect(!PrivilegeService.isManagedBridgeDaemonSupported)
        #elseif os(macOS)
            #expect(PlatformCapabilities.supportsManagedBridgeDaemon)
            #expect(PrivilegeService.isManagedBridgeDaemonSupported)
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
}
