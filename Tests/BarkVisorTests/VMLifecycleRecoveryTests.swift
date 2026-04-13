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
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
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
                isoId: nil,
                isoIds: nil,
                networkId: nil,
                cloudInitPath: "/tmp/cloud-init/vm-1/cidata.iso",
                vncPort: nil,
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
                isoId: nil,
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                vncPort: nil,
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
}
