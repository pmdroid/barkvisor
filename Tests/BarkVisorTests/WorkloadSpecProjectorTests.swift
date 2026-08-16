import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct WorkloadSpecProjectorTests {
    /// CI macOS runners have 3 logical CPUs; Linux runners have 4.
    /// Keep fixtures at or below that so apply/validate do not host-cap.
    private var fixtureCPUCount: Int {
        min(2, max(1, PlatformHost.cpuCount))
    }

    private func makeVM() -> VM {
        VM(
            id: "vm-1",
            name: "media",
            vmType: "linux-arm64",
            state: "running",
            cpuCount: fixtureCPUCount,
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
        #expect(spec.spec.resources.cpu == fixtureCPUCount)
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
        #expect(spec.spec.networks.first?.mode == nil)
        #expect(spec.spec.networks.first?.mac == "52:54:00:12:34:56")
        #expect(spec.spec.networks.first?.portForwards.first?.proto == "tcp")
        #expect(spec.spec.cloudInit?.userDataRef == "/data/cidata.iso")
        #expect(spec.spec.usb.first?.vendorId == "0x1234")
        #expect(spec.spec.display?.resolution == "1280x800")
        #expect(spec.spec.sharedPaths == ["/Users/test/share"])
        #expect(spec.spec.health == nil)
    }

    @Test func `round trip apply does not lose column values`() throws {
        var vm = makeVM()
        let spec = WorkloadSpecProjector.fromVM(vm)
        try WorkloadSpecProjector.apply(spec, to: &vm)

        #expect(vm.name == "media")
        #expect(vm.vmType == "linux-arm64")
        #expect(vm.cpuCount == fixtureCPUCount)
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
        #expect(status.health == .running)
        #expect(status.healthError == nil)
        #expect(status.backend == WorkloadBackendProjector.project(guestType: "linux-arm64"))
        #expect(status.backend.qemuBinary == "qemu-system-aarch64")
        #expect(status.backend.guestArch == "arm64")
        #expect(status.backend.accelerator == QEMUBuilder.accelerator)
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
            osFamily: nil,
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
        #expect(params.vmType == "linux-arm64")
        #expect(params.cpuCount == 2)
        #expect(params.memoryMB == 1_024)
    }

    @Test func `create params defaults omitted vmType from host`() throws {
        let body = CreateVMRequest(
            name: "simple",
            vmType: nil,
            osFamily: nil,
            cpuCount: 2,
            memoryMB: 1_024,
            diskSizeGB: 10,
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
        #expect(params.vmType == GuestProfiles.defaultLinuxID(
            forImageArch: PlatformCapabilities.hostArch,
        ))
    }

    @Test func `create params osFamily windows defaults to host profile`() throws {
        let body = CreateVMRequest(
            name: "win",
            vmType: nil,
            osFamily: "windows",
            cpuCount: 2,
            memoryMB: 4_096,
            diskSizeGB: 64,
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
        let expected = try GuestProfiles.defaultID(osFamily: "windows")
        #expect(params.vmType == expected)
    }

    @Test func `create params explicit vmType wins over osFamily`() throws {
        let hostLinux = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        let body = CreateVMRequest(
            name: "named",
            vmType: hostLinux,
            osFamily: "windows",
            cpuCount: 2,
            memoryMB: 1_024,
            diskSizeGB: 10,
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
        #expect(params.vmType == hostLinux)
    }

    @Test func `create params from spec document`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "from-spec", description: "d"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 4_096),
                guestType: "linux-amd64",
                firmware: WorkloadFirmware(uefi: true, tpm: false),
            ),
        )
        let body = CreateVMRequest(
            name: nil, vmType: nil, osFamily: nil, cpuCount: nil, memoryMB: nil,
            diskSizeGB: 40, isoId: nil, cloudImageId: "img-1", cloudInit: nil,
            networkId: nil, existingDiskId: nil, sharedPaths: nil,
            portForwards: nil, usbDevices: nil, description: nil,
            bootOrder: nil, displayResolution: nil, uefi: nil, tpmEnabled: nil,
            spec: spec,
        )
        let params = try VMController.createParams(from: body)
        #expect(params.name == "from-spec")
        #expect(params.vmType == "linux-amd64")
        #expect(params.cpuCount == fixtureCPUCount)
        #expect(params.memoryMB == 4_096)
        #expect(params.diskSizeGB == 40)
        #expect(params.cloudImageId == "img-1")
    }

    @Test func `qemu builder resource args come from spec only`() {
        var spec = WorkloadSpecProjector.fromVM(makeVM())
        spec.spec.resources = WorkloadResources(cpu: 12, memoryMb: 1_536)
        #expect(QEMUBuilder.specResourceArgs(spec) == ["-smp", "12", "-m", "1536M"])
    }

    @Test func `apply rejects boot disk change`() throws {
        var vm = makeVM()
        var spec = WorkloadSpecProjector.fromVM(vm)
        for index in spec.spec.disks.indices where spec.spec.disks[index].role == "boot" {
            spec.spec.disks[index].diskId = "disk-other-vm"
        }
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.apply(spec, to: &vm)
        }
        #expect(vm.bootDiskId == "disk-boot")
    }

    @Test func `apply rejects arbitrary cloud-init host path`() throws {
        var vm = makeVM()
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.spec.cloudInit = WorkloadCloudInit(userDataRef: "/etc/passwd")
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.apply(spec, to: &vm)
        }
        #expect(vm.cloudInitPath == "/data/cidata.iso")
    }

    @Test func `apply accepts service-generated cloud-init ISO`() throws {
        var vm = makeVM()
        var spec = WorkloadSpecProjector.fromVM(vm)
        let generated = CloudInitService.generatedISOURL(vmID: vm.id).path
        spec.spec.cloudInit = WorkloadCloudInit(userDataRef: generated)
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.cloudInitPath == generated)
    }

    @Test func `validate rejects more vCPUs than the host has`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: PlatformHost.cpuCount + 1, memoryMb: 512),
            ),
        )
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.validate(spec)
        }
    }

    @Test func `validate accepts host logical CPU count`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: PlatformHost.cpuCount, memoryMb: 512),
            ),
        )
        try WorkloadSpecProjector.validate(spec)
    }

    @Test func `apply with empty disks preserves iso and data disks`() throws {
        var vm = makeVM()
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.metadata.description = "updated"
        spec.spec.disks = []
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.bootDiskId == "disk-boot")
        #expect(vm.decodedISOIds == ["iso-1"])
        #expect(vm.decodedAdditionalDiskIds == ["disk-data"])
        #expect(vm.description == "updated")
    }

    @Test func `apply with explicit disks replaces data and iso attachments`() throws {
        var vm = makeVM()
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.spec.disks = [WorkloadDisk(role: "boot", diskId: "disk-boot")]
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.bootDiskId == "disk-boot")
        #expect(vm.decodedISOIds.isEmpty)
        #expect(vm.decodedAdditionalDiskIds.isEmpty)
    }

    @Test func `create params from spec uses spec cloudInit inline`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "from-spec"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 2, memoryMb: 1_024),
                guestType: "linux-amd64",
                cloudInit: WorkloadCloudInit(inline: "packages:\n  - vim\n"),
            ),
        )
        let body = CreateVMRequest(
            name: nil, vmType: nil, osFamily: nil, cpuCount: nil, memoryMB: nil,
            diskSizeGB: 20, isoId: nil, cloudImageId: nil, cloudInit: nil,
            networkId: nil, existingDiskId: nil, sharedPaths: nil,
            portForwards: nil, usbDevices: nil, description: nil,
            bootOrder: nil, displayResolution: nil, uefi: nil, tpmEnabled: nil,
            spec: spec,
        )
        let params = try VMController.createParams(from: body)
        #expect(params.cloudInit?.userData == "packages:\n  - vim\n")
    }

    @Test func `create params prefers flat cloudInit over spec inline`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "from-spec"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 2, memoryMb: 1_024),
                guestType: "linux-amd64",
                cloudInit: WorkloadCloudInit(inline: "packages:\n  - vim\n"),
            ),
        )
        let body = CreateVMRequest(
            name: nil, vmType: nil, osFamily: nil, cpuCount: nil, memoryMB: nil,
            diskSizeGB: 20, isoId: nil, cloudImageId: nil,
            cloudInit: CloudInitConfig(sshAuthorizedKeys: nil, userData: "runcmd:\n  - echo hi\n"),
            networkId: nil, existingDiskId: nil, sharedPaths: nil,
            portForwards: nil, usbDevices: nil, description: nil,
            bootOrder: nil, displayResolution: nil, uefi: nil, tpmEnabled: nil,
            spec: spec,
        )
        let params = try VMController.createParams(from: body)
        #expect(params.cloudInit?.userData == "runcmd:\n  - echo hi\n")
    }

    @Test func `metadata-only spec apply is not a hardware change`() throws {
        let before = makeVM()
        var after = makeVM()
        var spec = WorkloadSpecProjector.fromVM(after)
        spec.metadata.name = "renamed"
        spec.metadata.description = "only metadata"
        try WorkloadSpecProjector.apply(spec, to: &after)
        #expect(after.name == "renamed")
        #expect(after.description == "only metadata")
        #expect(!VMLifecycleService.detectHardwareChanges(before: before, after: after))
    }

    @Test func `cpu change on spec apply is a hardware change`() throws {
        let before = makeVM()
        var after = makeVM()
        var spec = WorkloadSpecProjector.fromVM(after)
        spec.spec.resources.cpu = fixtureCPUCount == 1 ? min(2, PlatformHost.cpuCount) : 1
        try WorkloadSpecProjector.apply(spec, to: &after)
        #expect(after.cpuCount != before.cpuCount)
        #expect(VMLifecycleService.detectHardwareChanges(before: before, after: after))
    }

    @Test func `override-only spec apply is a hardware change`() throws {
        let before = makeVM()
        var after = makeVM()
        var spec = WorkloadSpecProjector.fromVM(after)
        spec.overrides = WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
            macos: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(cpu: fixtureCPUCount),
                accelerator: "tcg",
            ),
        )
        try WorkloadSpecProjector.apply(spec, to: &after)
        #expect(after.cpuCount == before.cpuCount)
        #expect(after.memoryMb == before.memoryMb)
        #expect(after.decodedOverrides != before.decodedOverrides)
        #expect(VMLifecycleService.detectHardwareChanges(before: before, after: after))
    }

    @Test func `fromVM projects implicit NAT when networkId is nil`() {
        var vm = makeVM()
        vm.networkId = nil
        let spec = WorkloadSpecProjector.fromVM(vm)
        #expect(spec.spec.networks.first?.mode == "nat")
        #expect(spec.spec.networks.first?.networkId == nil)
    }

    @Test func `validate rejects port forwards on isolated spec mode`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 512),
                networks: [
                    WorkloadNetwork(
                        mode: "isolated",
                        portForwards: [WorkloadPortForward(hostPort: 8_080, guestPort: 80, proto: "tcp")],
                    ),
                ],
            ),
        )
        let err = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.validate(spec)
        }
        #expect(err?.code == "invalid_port_forward")
        #expect(err?.httpStatus == 400)
    }
}
