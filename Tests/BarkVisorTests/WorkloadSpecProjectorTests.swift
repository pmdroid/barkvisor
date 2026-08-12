import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct WorkloadSpecProjectorTests {
    private func makeVM() -> VM {
        VM(
            id: "vm-1",
            name: "media",
            vmType: "linux-arm64",
            state: "running",
            cpuCount: 4,
            memoryMb: 8_192,
            bootDiskId: "disk-boot",
            isoIds: #"["iso-1"]"#,
            networkId: "net-1",
            cloudInitPath: "/data/cidata.iso",
            description: "HTPC",
            bootOrder: "cdn",
            displayResolution: "1280x800",
            additionalDiskIds: #"["disk-data"]"#,
            uefi: true,
            tpmEnabled: false,
            macAddress: "52:54:00:12:34:56",
            sharedPaths: #"["/Users/test/share"]"#,
            portForwards: #"[{"protocol":"tcp","hostPort":8080,"guestPort":80}]"#,
            usbDevices: #"[{"vendorId":"0x1234","productId":"0x5678","label":"stick"}]"#,
            autoCreated: false,
            pendingChanges: true,
            specGeneration: 3,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-06-01T00:00:00Z",
        )
    }

    @Test func `fromVM maps every column without host-only required fields`() {
        let spec = WorkloadSpecProjector.fromVM(makeVM())
        #expect(spec.apiVersion == WorkloadSpec.currentAPIVersion)
        #expect(spec.kind == WorkloadSpec.kindVirtualMachine)
        #expect(spec.metadata.id == "vm-1")
        #expect(spec.metadata.name == "media")
        #expect(spec.metadata.description == "HTPC")
        #expect(spec.spec.resources.cpu == 4)
        #expect(spec.spec.resources.memoryMb == 8_192)
        #expect(spec.spec.arch == "aarch64")
        #expect(spec.spec.guestType == "linux-arm64")
        #expect(spec.spec.osFamily == "linux")
        #expect(spec.spec.machine == "virt")
        #expect(spec.spec.firmware?.uefi == true)
        #expect(spec.spec.firmware?.tpm == false)
        #expect(spec.spec.bootOrder == "cdn")
        #expect(spec.spec.disks.contains { $0.role == "boot" && $0.diskId == "disk-boot" })
        #expect(spec.spec.disks.contains { $0.role == "data" && $0.diskId == "disk-data" })
        #expect(spec.spec.disks.contains { $0.role == "cdrom" && $0.imageId == "iso-1" })
        #expect(spec.spec.networks.first?.networkId == "net-1")
        #expect(spec.spec.networks.first?.mac == "52:54:00:12:34:56")
        #expect(spec.spec.networks.first?.portForwards.first?.proto == "tcp")
        #expect(spec.spec.cloudInit?.userDataRef == "/data/cidata.iso")
        #expect(spec.spec.usb.first?.vendorId == "0x1234")
        #expect(spec.spec.display?.resolution == "1280x800")
        #expect(spec.spec.sharedPaths == ["/Users/test/share"])
    }

    @Test func `round trip apply does not lose column values`() throws {
        var vm = makeVM()
        let spec = WorkloadSpecProjector.fromVM(vm)
        try WorkloadSpecProjector.apply(spec, to: &vm)

        #expect(vm.name == "media")
        #expect(vm.vmType == "linux-arm64")
        #expect(vm.cpuCount == 4)
        #expect(vm.memoryMb == 8_192)
        #expect(vm.bootDiskId == "disk-boot")
        #expect(vm.decodedISOIds == ["iso-1"])
        #expect(vm.decodedAdditionalDiskIds == ["disk-data"])
        #expect(vm.networkId == "net-1")
        #expect(vm.cloudInitPath == "/data/cidata.iso")
        #expect(vm.description == "HTPC")
        #expect(vm.bootOrder == "cdn")
        #expect(vm.displayResolution == "1280x800")
        #expect(vm.uefi)
        #expect(!vm.tpmEnabled)
        #expect(vm.macAddress == "52:54:00:12:34:56")
        #expect(vm.decodedSharedPaths == ["/Users/test/share"])
        #expect(vm.decodedPortForwards.first?.guestPort == 80)
        #expect(vm.decodedUSBDevices.first?.productId == "0x5678")
        // Host-only columns preserved
        #expect(vm.state == "running")
        #expect(vm.pendingChanges)
        #expect(vm.autoCreated == false)
        #expect(vm.specGeneration == 3)
    }

    @Test func `status uses closed state enum`() {
        let status = WorkloadSpecProjector.status(from: makeVM())
        #expect(status.state == .running)
        #expect(status.generation == 3)
        #expect(VMState.parse("not-a-state") == .error)
    }

    @Test func `resolveGuestType defaults arch from host`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(resources: WorkloadResources(cpu: 1, memoryMb: 512)),
        )
        let guest = try WorkloadSpecProjector.resolveGuestType(spec)
        let expected = GuestProfiles.defaultLinuxID(
            forImageArch: PlatformCapabilities.hostArch,
        )
        #expect(guest == expected)
    }

    @Test func `guestType and arch mismatch is rejected`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 1, memoryMb: 512),
                arch: "x86_64",
                guestType: "linux-arm64",
            ),
        )
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.validate(spec)
        }
    }

    @Test func `create params from spec keeps flat create working`() throws {
        let body = CreateVMRequest(
            name: "flat",
            vmType: "linux-arm64",
            cpuCount: 2,
            memoryMB: 1_024,
            diskSizeGB: 20,
            isoId: nil,
            cloudImageId: nil,
            cloudInit: nil,
            networkId: nil,
            existingDiskId: nil,
            sharedPaths: nil,
            portForwards: nil,
            usbDevices: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            uefi: nil,
            tpmEnabled: nil,
            spec: nil,
        )
        let params = try VMController.createParams(from: body)
        #expect(params.name == "flat")
        #expect(params.cpuCount == 2)
        #expect(params.memoryMB == 1_024)
    }

    @Test func `create params from spec document`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "from-spec", description: "d"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 8, memoryMb: 4_096),
                guestType: "linux-amd64",
                firmware: WorkloadFirmware(uefi: true, tpm: false),
            ),
        )
        let body = CreateVMRequest(
            name: nil, vmType: nil, cpuCount: nil, memoryMB: nil,
            diskSizeGB: 40, isoId: nil, cloudImageId: "img-1", cloudInit: nil,
            networkId: nil, existingDiskId: nil, sharedPaths: nil,
            portForwards: nil, usbDevices: nil, description: nil,
            bootOrder: nil, displayResolution: nil, uefi: nil, tpmEnabled: nil,
            spec: spec,
        )
        let params = try VMController.createParams(from: body)
        #expect(params.name == "from-spec")
        #expect(params.vmType == "linux-amd64")
        #expect(params.cpuCount == 8)
        #expect(params.memoryMB == 4_096)
        #expect(params.diskSizeGB == 40)
        #expect(params.cloudImageId == "img-1")
    }

    @Test func `qemu builder resource args come from spec only`() {
        var spec = WorkloadSpecProjector.fromVM(makeVM())
        spec.spec.resources = WorkloadResources(cpu: 12, memoryMb: 1_536)
        #expect(QEMUBuilder.specResourceArgs(spec) == ["-smp", "12", "-m", "1536M"])
    }
}
