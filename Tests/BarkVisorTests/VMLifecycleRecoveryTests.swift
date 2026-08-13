import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class VMLifecycleRecoveryTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func `handle provision failure marks VM error and removes disk file`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("boot.qcow2")
        FileManager.default.createFile(atPath: diskPath.path, contents: Data("partial".utf8))

        try await dbPool.write { db in
            try Disk(
                id: "disk-1",
                name: "boot",
                path: diskPath.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-1",
                autoCreated: false,
                status: "creating",
                createdAt: now,
            ).insert(db)

            try VM(
                id: "vm-1",
                name: "test-vm",
                vmType: "linux-arm64",
                state: "provisioning",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-1",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: "/tmp/cloud-init/vm-1/cidata.iso",
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        await VMLifecycleService.handleProvisionFailure(
            vmID: "vm-1",
            diskID: "disk-1",
            diskPath: diskPath.path,
            db: dbPool,
            error: BarkVisorError.internalError("boom"),
        )

        let vm = try await dbPool.read { db in
            try VM.fetchOne(db, key: "vm-1")
        }
        let disk = try await dbPool.read { db in
            try Disk.fetchOne(db, key: "disk-1")
        }

        #expect(vm?.state == "error")
        #expect(vm?.cloudInitPath == nil)
        #expect(disk?.status == "creating")
        #expect(!FileManager.default.fileExists(atPath: diskPath.path))
    }

    @Test func `handle delete failure marks VM error`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("delete.qcow2")
        FileManager.default.createFile(atPath: diskPath.path, contents: Data())

        try await dbPool.write { db in
            try Disk(
                id: "disk-2",
                name: "boot",
                path: diskPath.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-2",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)

            try VM(
                id: "vm-2",
                name: "delete-vm",
                vmType: "linux-arm64",
                state: "deleting",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-2",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        await VMLifecycleService.handleDeleteFailure(
            vmID: "vm-2",
            db: dbPool,
            error: BarkVisorError.internalError("boom"),
        )

        let vm = try await dbPool.read { db in
            try VM.fetchOne(db, key: "vm-2")
        }

        #expect(vm?.state == "error")
    }

    @Test func `updateVMSpec metadata only does not set pendingChanges on running VM`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("spec-meta.qcow2").path
        try await dbPool.write { db in
            try Disk(
                id: "disk-spec-meta",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-spec-meta",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: "vm-spec-meta",
                name: "running-vm",
                vmType: "linux-arm64",
                state: "running",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-spec-meta",
                isoIds: #"["iso-1"]"#,
                networkId: nil,
                cloudInitPath: nil,
                description: "old",
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: #"["disk-data"]"#,
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
            ).insert(db)
        }

        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec-meta") }
        guard var spec = existing.map(WorkloadSpecProjector.fromVM) else {
            Issue.record("expected VM")
            return
        }
        spec.metadata.description = "only metadata"
        spec.spec.disks = []

        let updated = try await VMLifecycleService.updateVMSpec(
            id: "vm-spec-meta", spec: spec, db: dbPool,
        )
        #expect(updated.description == "only metadata")
        #expect(!updated.pendingChanges)
        #expect(updated.decodedISOIds == ["iso-1"])
        #expect(updated.decodedAdditionalDiskIds == ["disk-data"])
    }

    @Test func `updateVMSpec hardware change sets pendingChanges on running VM`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("spec-hw.qcow2").path
        try await dbPool.write { db in
            try Disk(
                id: "disk-spec-hw",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-spec-hw",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: "vm-spec-hw",
                name: "running-hw-vm",
                vmType: "linux-arm64",
                state: "running",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-spec-hw",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec-hw") }
        guard var spec = existing.map(WorkloadSpecProjector.fromVM) else {
            Issue.record("expected VM")
            return
        }
        spec.spec.resources.cpu = 1

        let updated = try await VMLifecycleService.updateVMSpec(
            id: "vm-spec-hw", spec: spec, db: dbPool,
        )
        #expect(updated.cpuCount == 1)
        #expect(updated.pendingChanges)
    }

    @Test func `updateVMSpec override-only sets pendingChanges on running VM`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let cpuCount = min(2, max(1, PlatformHost.cpuCount))
        let diskPath = tmpDir.appendingPathComponent("spec-ov.qcow2").path
        try await dbPool.write { db in
            try Disk(
                id: "disk-spec-ov",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-spec-ov",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: "vm-spec-ov",
                name: "running-ov-vm",
                vmType: "linux-arm64",
                state: "running",
                cpuCount: cpuCount,
                memoryMb: 2_048,
                bootDiskId: "disk-spec-ov",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec-ov") }
        guard var spec = existing.map(WorkloadSpecProjector.fromVM) else {
            Issue.record("expected VM")
            return
        }
        spec.overrides = WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
            macos: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
        )

        let updated = try await VMLifecycleService.updateVMSpec(
            id: "vm-spec-ov", spec: spec, db: dbPool,
        )
        #expect(updated.cpuCount == cpuCount)
        #expect(updated.memoryMb == 2_048)
        #expect(updated.decodedOverrides?.linux?.resources?.memoryMb == 4_096)
        #expect(updated.decodedOverrides?.macos?.accelerator == "tcg")
        #expect(updated.pendingChanges)
    }
}
