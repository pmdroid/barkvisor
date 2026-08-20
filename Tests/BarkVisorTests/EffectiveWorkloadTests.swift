import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct EffectiveWorkloadTests {
    /// CI macOS runners have 3 logical CPUs; Linux runners have 4.
    private var fixtureCPUCount: Int {
        min(2, max(1, PlatformHost.cpuCount))
    }

    private var hostLinux: String {
        GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
    }

    private func makeVM() -> VM {
        VM(
            id: "vm-1",
            name: "media",
            vmType: hostLinux,
            state: "stopped",
            cpuCount: fixtureCPUCount,
            memoryMb: 1_024,
            bootDiskId: "disk-boot",
            isoIds: #"["iso-1"]"#,
            networkId: nil,
            cloudInitPath: nil,
            description: "HTPC",
            bootOrder: "cdn",
            displayResolution: "1280x800",
            additionalDiskIds: #"["disk-data"]"#,
            uefi: true,
            tpmEnabled: false,
            macAddress: "52:54:00:12:34:56",
            sharedPaths: nil,
            portForwards: nil,
            usbDevices: nil,
            autoCreated: false,
            pendingChanges: false,
            specGeneration: 1,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-06-01T00:00:00Z",
        )
    }

    @Test func `document evaluates to a validated portable spec`() throws {
        let document: [String: Any] = [
            "apiVersion": WorkloadSpec.currentAPIVersion,
            "kind": WorkloadSpec.kindVirtualMachine,
            "metadata": ["name": "web"],
            "spec": [
                "resources": ["cpu": fixtureCPUCount, "memoryMb": 512],
                "guestType": hostLinux,
                "disks": [["role": "boot", "diskId": "disk-1"]],
            ],
        ]
        let effective = try EffectiveWorkloadPipeline.evaluate(document: document)
        #expect(effective.portable.metadata.name == "web")
        #expect(effective.portable.spec.resources.cpu == fixtureCPUCount)
        #expect(effective.portableGuestType == hostLinux)
        #expect(effective.launchGuestType == hostLinux)
        #expect(effective.resolved.spec.resources.cpu == fixtureCPUCount)
    }

    @Test func `record projects columns and reads specJson`() throws {
        var vm = makeVM()
        #expect(vm.specJson == nil)
        let beforeWrite = try EffectiveWorkloadPipeline.evaluate(vm: vm)
        #expect(beforeWrite.storedDocument == nil)
        #expect(beforeWrite.portable.metadata.id == "vm-1")
        #expect(beforeWrite.portableGuestType == hostLinux)

        vm.syncSpecProjection(bumpGeneration: false)
        let afterWrite = try EffectiveWorkloadPipeline.evaluate(vm: vm)
        #expect(afterWrite.storedDocument == afterWrite.portable)
        #expect(afterWrite.storedDocument?.spec.disks.contains {
            $0.role == "boot" && $0.diskId == "disk-boot"
        } == true)
    }

    @Test func `create params include health from spec`() throws {
        let health = WorkloadHealthSpec(
            http: WorkloadHealthHTTPCheck(path: "/", port: 80),
        )
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(id: "vm-h", name: "healthy"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 512),
                guestType: hostLinux,
                disks: [WorkloadDisk(role: "boot", diskId: "disk-1")],
                health: health,
            ),
        )
        let apply = try EffectiveWorkloadPipeline.createParams(from: spec, extras: .apply)
        #expect(apply.health == health)
        #expect(apply.id == "vm-h")
        #expect(apply.existingDiskId == "disk-1")

        let body = CreateVMRequest(
            name: nil, vmType: nil, osFamily: nil, cpuCount: nil, memoryMB: nil,
            diskSizeGB: 40, isoId: nil, cloudImageId: "img-1", cloudInit: nil,
            networkId: nil, existingDiskId: nil, sharedPaths: nil,
            portForwards: nil, usbDevices: nil, description: nil,
            bootOrder: nil, displayResolution: nil, uefi: nil, tpmEnabled: nil,
            spec: spec,
        )
        let viaController = try VMController.createParams(from: body)
        #expect(viaController.health == health)
        #expect(viaController.diskSizeGB == 40)
        #expect(viaController.cloudImageId == "img-1")
        #expect(viaController.existingDiskId == "disk-1")
    }

    @Test func `iso create defaults disk size only on apply extras`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "iso-vm"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 512),
                guestType: hostLinux,
                disks: [WorkloadDisk(role: "cdrom", imageId: "iso-1")],
            ),
        )
        let apply = try EffectiveWorkloadPipeline.createParams(from: spec, extras: .apply)
        #expect(apply.diskSizeGB == WorkloadApplyService.defaultCreateDiskSizeGB)
        #expect(apply.isoId == "iso-1")

        let noDefault = try EffectiveWorkloadPipeline.createParams(from: spec)
        #expect(noDefault.diskSizeGB == nil)
        #expect(noDefault.isoId == "iso-1")
    }

    @Test func `apply extras reject create without boot media`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "empty"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 512),
                guestType: hostLinux,
            ),
        )
        #expect(throws: BarkVisorError.self) {
            _ = try EffectiveWorkloadPipeline.createParams(from: spec, extras: .apply)
        }
    }

    @Test func `evaluate rejects more vCPUs than the host has`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "too-many"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: PlatformHost.cpuCount + 1, memoryMb: 512),
                guestType: hostLinux,
            ),
        )
        #expect(throws: BarkVisorError.self) {
            _ = try EffectiveWorkloadPipeline.evaluate(spec)
        }
    }

    @Test func `qemu device names match builder drive ids`() throws {
        #expect(QEMUDeviceNames.bootDrive == "boot0")
        #expect(QEMUDeviceNames.extraDrive(0) == "extra0")
        #expect(QEMUDeviceNames.extraDrive(2) == "extra2")
        #expect(QEMUDeviceNames.cdromDrive(0) == "cdrom0")
        #expect(
            try QEMUDeviceNames.blockDevice(
                diskId: "disk-boot",
                bootDiskId: "disk-boot",
                additionalDiskIds: ["disk-data"],
            ) == "boot0",
        )
        #expect(
            try QEMUDeviceNames.blockDevice(
                diskId: "disk-data",
                bootDiskId: "disk-boot",
                additionalDiskIds: ["disk-data"],
            ) == "extra0",
        )
        #expect(throws: BarkVisorError.self) {
            _ = try QEMUDeviceNames.blockDevice(
                diskId: "missing",
                bootDiskId: "disk-boot",
                additionalDiskIds: ["disk-data"],
            )
        }
    }

    @Test func `guest type uses GuestProfiles not a new table`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "g"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 512),
                osFamily: "linux",
            ),
        )
        let effective = try EffectiveWorkloadPipeline.evaluate(spec)
        #expect(effective.portableGuestType == hostLinux)
        #expect(try GuestProfiles.require(effective.portableGuestType).id == hostLinux)
    }
}
