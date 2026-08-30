import Foundation
import Testing
@testable import BarkVisorCore

struct VMJSONColumnTests {
    private func makeVM(
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
            isoIds: isoIds,
            networkId: nil,
            cloudInitPath: nil,
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

    @Test func `guest addressing json round trip`() {
        var vm = makeVM()
        vm.setGuestAddressing(
            GuestAddressing(
                mode: "static", ipv4: "10.0.0.8", prefixLength: 24, gateway: "10.0.0.1",
            ),
        )
        #expect(vm.decodedGuestAddressing?.ipv4 == "10.0.0.8")
        #expect(WorkloadSpecJSON.decode(vm.specJson)?.spec.networks.first?.addressing?.ipv4 == "10.0.0.8")
        vm.setGuestAddressing(nil)
        #expect(vm.decodedGuestAddressing == nil)
    }

    @Test func `health json round trip`() {
        var vm = makeVM()
        vm.setHealth(
            WorkloadHealthSpec(http: WorkloadHealthHTTPCheck(path: "/ready", port: 8_080)),
        )
        #expect(vm.decodedHealth?.http?.path == "/ready")
        vm.setHealth(WorkloadHealthSpec())
        #expect(vm.decodedHealth == nil)
    }

    @Test func `decodedISOIds uses array`() {
        var vm = makeVM(isoIds: #"["a","b"]"#)
        #expect(vm.decodedISOIds == ["a", "b"])

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
        #expect(vm.decodedHealth == nil)
        #expect(vm.decodedSession == nil)
    }

    @Test func `session json round trip`() {
        var vm = makeVM()
        vm.setSession(
            CodingAgentLifecycle.seed(
                ttlSeconds: 3_600, grant: "home-ollama", cloudImageId: "img-1", diskSizeGB: 20,
            ),
        )
        #expect(vm.decodedSession?.grant == "home-ollama")
        #expect(vm.decodedSession?.cloudImageId == "img-1")
        vm.setSession(nil)
        #expect(vm.decodedSession == nil)
    }

    @Test func `setters encode empty as nil`() {
        var vm = makeVM()
        vm.setISOIds(["x", "y"])
        #expect(vm.isoIds != nil)
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
        let gpu = GPUPassthroughDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
        )
        vm.setGPUDevices([gpu])
        #expect(vm.decodedGPUDevices.count == 1)
        vm.setGPUDevices([])
        #expect(vm.gpuDevices == nil)
    }

    @Test func `decodeArrayOrEmpty handles nil blank and valid`() {
        #expect(JSONColumnCoding.decodeArrayOrEmpty(String.self, from: nil).isEmpty)
        #expect(JSONColumnCoding.decodeArrayOrEmpty(String.self, from: "").isEmpty)
        #expect(JSONColumnCoding.decodeArrayOrEmpty(String.self, from: #"["a"]"#) == ["a"])
    }
}
