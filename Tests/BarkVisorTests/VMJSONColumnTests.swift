import Foundation
import Testing
@testable import BarkVisorCore

struct VMJSONColumnTests {
    private func makeVM(
        isoId: String? = nil,
        isoIds: String? = nil,
        additionalDiskIds: String? = nil,
        sharedPaths: String? = nil,
        portForwards: String? = nil,
        usbDevices: String? = nil,
    ) -> VM {
        VM(
            id: "vm-1",
            name: "t",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: 2,
            memoryMb: 2_048,
            bootDiskId: "disk-1",
            isoId: isoId,
            isoIds: isoIds,
            networkId: nil,
            cloudInitPath: nil,
            vncPort: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: additionalDiskIds,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: sharedPaths,
            portForwards: portForwards,
            usbDevices: usbDevices,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2020-01-01T00:00:00Z",
            updatedAt: "2020-01-01T00:00:00Z",
        )
    }

    @Test func `decodedISOIds uses array and legacy fallback`() {
        var vm = makeVM(isoIds: #"["a","b"]"#)
        #expect(vm.decodedISOIds == ["a", "b"])

        vm = makeVM(isoId: "legacy-only")
        #expect(vm.decodedISOIds == ["legacy-only"])

        vm = makeVM()
        #expect(vm.decodedISOIds.isEmpty)
    }

    @Test func `corrupt JSON yields empty not crash`() {
        let vm = makeVM(
            isoIds: "{not-json",
            additionalDiskIds: "null",
            sharedPaths: "[1,2]",
            portForwards: "oops",
            usbDevices: "{",
        )
        #expect(vm.decodedISOIds.isEmpty)
        #expect(vm.decodedAdditionalDiskIds.isEmpty)
        #expect(vm.decodedSharedPaths.isEmpty)
        #expect(vm.decodedPortForwards.isEmpty)
        #expect(vm.decodedUSBDevices.isEmpty)
    }

    @Test func `setters encode empty as nil`() {
        var vm = makeVM()
        vm.setISOIds(["x", "y"])
        #expect(vm.isoIds != nil)
        #expect(vm.isoId == nil)
        #expect(vm.decodedISOIds == ["x", "y"])

        vm.setISOIds([])
        #expect(vm.isoIds == nil)

        vm.setSharedPaths(["/tmp"])
        #expect(vm.decodedSharedPaths == ["/tmp"])
        vm.setSharedPaths([])
        #expect(vm.sharedPaths == nil)

        let usb = USBPassthroughDevice(vendorId: "0x1234", productId: "0x5678", label: "t")
        vm.setUSBDevices([usb])
        #expect(vm.decodedUSBDevices.count == 1)
        vm.setUSBDevices([])
        #expect(vm.usbDevices == nil)
    }

    @Test func `decodeArrayOrEmpty handles nil blank and valid`() {
        #expect(JSONColumnCoding.decodeArrayOrEmpty(String.self, from: nil).isEmpty)
        #expect(JSONColumnCoding.decodeArrayOrEmpty(String.self, from: "").isEmpty)
        #expect(JSONColumnCoding.decodeArrayOrEmpty(String.self, from: #"["a"]"#) == ["a"])
    }
}
