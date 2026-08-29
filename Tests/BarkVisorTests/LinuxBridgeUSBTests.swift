import Foundation
import Testing
@testable import BarkVisorCore

struct LinuxBridgeUSBTests {
    @Test func `capabilities enable bridge and usb on supported hosts`() throws {
        #if os(Linux) || os(macOS)
            #expect(PlatformCapabilities.supportsBridgedNetworking)
            #expect(PlatformCapabilities.supportsUSBPassthrough)
        #endif
        #if os(Linux)
            // Linux uses host bridges + QEMU -netdev bridge — not a managed daemon.
            #expect(!PlatformCapabilities.supportsManagedBridgeDaemon)
            #expect(PlatformCapabilities.supportsHostMutation)
            #expect(PlatformCapabilities.supportsHostBridgeManagement)
            let err = #expect(throws: BarkVisorError.self) {
                try PlatformCapabilities.requireManagedBridgeDaemon()
            }
            #expect(err?.httpStatus == 422)
            #expect(err?.code == "managed_bridge_daemon")
            try PlatformCapabilities.requireHostMutation()
        #elseif os(macOS)
            #expect(PlatformCapabilities.supportsManagedBridgeDaemon)
            #expect(PlatformCapabilities.supportsHostMutation)
            #expect(!PlatformCapabilities.supportsHostBridgeManagement)
            try PlatformCapabilities.requireManagedBridgeDaemon()
            try PlatformCapabilities.requireHostMutation()
        #endif
    }

    @Test func `parse lsusb line extracts vendor product and name`() {
        let line = "Bus 001 Device 004: ID 046d:c52b Logitech, Inc. Unifying Receiver"
        let dev = USBDeviceService.parseLsusbLine(line)
        #expect(dev != nil)
        #expect(dev?.vendorId == "0x046d")
        #expect(dev?.productId == "0xc52b")
        #expect(dev?.name.contains("Logitech") == true)
        #expect(dev?.bus == 1)
        #expect(dev?.address == 4)
        #expect(dev?.id == "bus:001.004")
        #expect(dev?.idUnstable == true)
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
            #expect(err?.httpStatus == 422)
            #expect(err?.code == "interface_missing")
        #endif
    }

    @Test func `bridge ACL comments and allow all`() {
        let contents = """
        # qemu-bridge-helper
        allow virbr0
        allow br0 # lab
        """
        #expect(LinuxHostNetwork.bridgeACLAllows("br0", fileContents: contents))
        #expect(LinuxHostNetwork.bridgeACLAllows("virbr0", fileContents: contents))
        #expect(!LinuxHostNetwork.bridgeACLAllows("docker0", fileContents: contents))
        #expect(LinuxHostNetwork.bridgeACLAllows("docker0", fileContents: "allow all\n"))
    }

    @Test func `missing or empty ACL is deny for persist gate`() throws {
        #expect(!LinuxHostNetwork.bridgeACLPermits("br0", at: "/no/such/qemu-bridge.conf"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("bridge.conf").path
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(!LinuxHostNetwork.bridgeACLPermits("br0", at: path))
        try "allow br0\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(LinuxHostNetwork.bridgeACLPermits("br0", at: path))
        #expect(!LinuxHostNetwork.bridgeACLPermits("docker0", at: path))
    }
}
