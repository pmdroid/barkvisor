import Foundation
import GRDB
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
            workloadClass: nil,
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

    @Test func `flat windows create with uefi keeps tpm omitted`() throws {
        let windows = try GuestProfiles.defaultID(osFamily: "windows")
        let spec = try EffectiveWorkloadPipeline.specFromFlat(
            name: "win",
            vmType: windows,
            osFamily: nil,
            cpuCount: fixtureCPUCount,
            memoryMB: 4_096,
            uefi: true,
            tpmEnabled: nil,
        )
        #expect(spec.spec.firmware == nil)
        let params = try EffectiveWorkloadPipeline.createParams(
            from: spec,
            extras: CreateWorkloadExtras(uefi: true),
        )
        #expect(params.uefi == true)
        #expect(params.tpmEnabled == nil)
        #expect(params.vmType.hasPrefix("windows"))
    }
}

final class EffectiveWorkloadCreateTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let hostLinux: String
    private let fixtureCPUCount: Int
    private let backgroundTasks = BackgroundTaskManager()

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
        hostLinux = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        fixtureCPUCount = min(2, max(1, PlatformHost.cpuCount))
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func `duplicate create id does not attach a free disk`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let guest = hostLinux
        let cpus = fixtureCPUCount
        let takenBoot = tmpDir.appendingPathComponent("disk-taken-boot.qcow2")
        FileManager.default.createFile(atPath: takenBoot.path, contents: Data())
        try await dbPool.write { db in
            try Disk(
                id: "disk-taken-boot",
                name: "taken-boot",
                path: takenBoot.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            var existing = VM(
                id: "vm-taken",
                name: "taken",
                vmType: guest,
                state: "stopped",
                cpuCount: cpus,
                memoryMb: 512,
                bootDiskId: "disk-taken-boot",
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: nil,
                displayResolution: nil,
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: "52:54:00:00:00:01",
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            )
            existing.syncSpecProjection(bumpGeneration: false)
            try existing.insert(db)
        }
        let freePath = tmpDir.appendingPathComponent("disk-free.qcow2")
        FileManager.default.createFile(atPath: freePath.path, contents: Data())
        try await dbPool.write { db in
            try Disk(
                id: "disk-free",
                name: "free",
                path: freePath.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
        }

        let params = CreateVMParams(
            id: "vm-taken",
            name: "collision",
            vmType: hostLinux,
            cpuCount: fixtureCPUCount,
            memoryMB: 512,
            existingDiskId: "disk-free",
        )
        let err = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.createVM(
                params: params, db: dbPool, backgroundTasks: backgroundTasks,
            )
        }
        if case let .conflict(message) = err {
            #expect(message.contains("vm-taken"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
        let disk = try #require(try await dbPool.read { db in try Disk.fetchOne(db, key: "disk-free") })
        #expect(disk.vmId == nil)
    }
}
