import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct DatabaseMigrationTests {
    private func makeInMemoryMigrator() -> DatabaseMigrator {
        return AppDatabase.makeMigrator()
    }

    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try makeInMemoryMigrator().migrate(queue)
        return queue
    }

    // MARK: - Migration Integrity

    @Test func `all migrations run without error`() throws {
        #expect(throws: Never.self) { try migratedQueue() }
    }

    @Test func `migrations are idempotent`() throws {
        let queue = try migratedQueue()
        #expect(throws: Never.self) { try makeInMemoryMigrator().migrate(queue) }
    }

    // MARK: - VM Round Trip

    @Test func `vm round trip`() throws {
        let queue = try migratedQueue()

        let disk = Disk(
            id: "disk-1", name: "boot", path: "/data/boot.qcow2",
            sizeBytes: 21_474_836_480, format: "qcow2", vmId: nil,
            autoCreated: false, status: "ready", createdAt: "2025-01-01T00:00:00Z",
        )
        try queue.write { db in try disk.insert(db) }

        let vm = VM(
            id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-1", networkId: nil, cloudInitPath: nil,
            description: nil, bootOrder: "cd", displayResolution: "1280x800",
            additionalDiskIds: nil, uefi: true, tpmEnabled: false,
            macAddress: "52:54:00:12:34:56", sharedPaths: nil,
            portForwards: nil, autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        try queue.write { db in try vm.insert(db) }
        let fetched = try queue.read { db in try VM.fetchOne(db, key: "vm-1") }

        #expect(fetched != nil)
        #expect(fetched?.name == "test")
        #expect(fetched?.vmType == "linux-arm64")
        #expect(fetched?.cpuCount == 2)
        #expect(fetched?.memoryMb == 1_024)
        #expect(fetched?.macAddress == "52:54:00:12:34:56")
    }

    // MARK: - Disk Round Trip

    @Test func `disk round trip`() throws {
        let queue = try migratedQueue()
        let disk = Disk(
            id: "disk-1", name: "boot", path: "/data/boot.qcow2",
            sizeBytes: 21_474_836_480, format: "qcow2", vmId: nil,
            autoCreated: false, status: "ready", createdAt: "2025-01-01T00:00:00Z",
        )

        try queue.write { db in try disk.insert(db) }
        let fetched = try queue.read { db in try Disk.fetchOne(db, key: "disk-1") }

        #expect(fetched != nil)
        #expect(fetched?.name == "boot")
        #expect(fetched?.sizeBytes == 21_474_836_480)
        #expect(fetched?.format == "qcow2")
    }

    // MARK: - Network Round Trip

    @Test func `network round trip`() throws {
        let queue = try migratedQueue()
        let network = Network(
            id: "net-1", name: "default", mode: "nat", bridge: nil,
            macAddress: nil, dnsServer: "8.8.8.8", autoCreated: true, isDefault: true,
        )

        try queue.write { db in try network.insert(db) }
        let fetched = try queue.read { db in try Network.fetchOne(db, key: "net-1") }

        #expect(fetched != nil)
        #expect(fetched?.name == "default")
        #expect(fetched?.mode == "nat")
        #expect(fetched?.dnsServer == "8.8.8.8")
        #expect(fetched?.isDefault == true)
    }

    // MARK: - PAS-35 M002

    @Test func `m002 folds isoId drops vncPort and backfills specJson`() throws {
        let queue = try DatabaseQueue()
        var m001 = DatabaseMigrator()
        m001.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try m001.migrate(queue)

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO images (id, name, imageType, arch, status, createdAt, updatedAt)
                VALUES (
                    'iso-legacy', 'legacy.iso', 'iso', 'arm64', 'ready',
                    '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z'
                )
                """,
            )
            try db.execute(
                sql: """
                INSERT INTO disks (id, name, path, sizeBytes, format, autoCreated, status, createdAt)
                VALUES ('d1', 'boot', '/tmp/d.qcow2', 1, 'qcow2', 0, 'ready', '2025-01-01T00:00:00Z')
                """,
            )
            try db.execute(
                sql: """
                INSERT INTO vms (
                    id, name, vmType, state, cpuCount, memoryMb, bootDiskId,
                    isoId, vncPort, uefi, tpmEnabled, autoCreated, pendingChanges,
                    createdAt, updatedAt
                ) VALUES (
                    'vm-1', 'legacy', 'linux-arm64', 'stopped', 2, 1024, 'd1',
                    'iso-legacy', 5900, 1, 0, 0, 0,
                    '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z'
                )
                """,
            )
        }

        try AppDatabase.makeMigrator().migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "vms").map(\.name)
            #expect(!columns.contains("isoId"))
            #expect(!columns.contains("vncPort"))
            #expect(columns.contains("specJson"))
            #expect(columns.contains("specGeneration"))
            let vm = try VM.fetchOne(db, key: "vm-1")
            #expect(vm?.decodedISOIds == ["iso-legacy"])
            #expect(vm?.specJson != nil)
            #expect(vm?.specGeneration == 1)
            let spec = WorkloadSpecJSON.decode(vm?.specJson)
            #expect(spec?.metadata.name == "legacy")
            #expect(spec?.spec.disks.contains { $0.role == "cdrom" && $0.imageId == "iso-legacy" } == true)
        }
    }

    @Test func `m004 adds overridesJson column`() throws {
        let queue = try migratedQueue()
        try queue.read { db in
            let columns = try db.columns(in: "vms").map(\.name)
            #expect(columns.contains("overridesJson"))
        }
    }

    @Test func `m005 adds healthJson column`() throws {
        let queue = try migratedQueue()
        try queue.read { db in
            let columns = try db.columns(in: "vms").map(\.name)
            #expect(columns.contains("healthJson"))
        }
    }

    @Test func `m006 adds sha256 column on images`() throws {
        let queue = try migratedQueue()
        try queue.read { db in
            let columns = try db.columns(in: "images").map(\.name)
            #expect(columns.contains("sha256"))
        }
    }

    @Test func `m006 leaves existing images sha256 null`() throws {
        let queue = try DatabaseQueue()
        var prior = DatabaseMigrator()
        prior.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        prior.registerMigration(M002_WorkloadSpec.identifier) { db in
            try M002_WorkloadSpec.migrate(db)
        }
        prior.registerMigration(M003_ArchitectureAwareTemplates.identifier) { db in
            try M003_ArchitectureAwareTemplates.migrate(db)
        }
        prior.registerMigration(M004_WorkloadOverrides.identifier) { db in
            try M004_WorkloadOverrides.migrate(db)
        }
        prior.registerMigration(M005_WorkloadHealth.identifier) { db in
            try M005_WorkloadHealth.migrate(db)
        }
        try prior.migrate(queue)

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO images (id, name, imageType, arch, status, createdAt, updatedAt)
                VALUES (
                    'img-legacy', 'legacy.iso', 'iso', 'arm64', 'ready',
                    '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z'
                )
                """,
            )
        }

        try AppDatabase.makeMigrator().migrate(queue)

        try queue.read { db in
            let image = try VMImage.fetchOne(db, key: "img-legacy")
            #expect(image?.name == "legacy.iso")
            #expect(image?.sha256 == nil)
        }
    }

    // MARK: - Tables Exist

    @Test func `expected tables exist`() throws {
        let queue = try migratedQueue()
        let tables = try queue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'grdb_%' ORDER BY name",
            )
        }

        let expected = [
            "api_keys", "app_settings", "audit_log", "bridges", "disks", "guest_info",
            "image_repositories", "images", "networks", "repository_images", "ssh_keys",
            "tus_uploads", "users", "vm_templates", "vms",
        ]
        for table in expected {
            #expect(tables.contains(table), "Expected table '\(table)' to exist, got: \(tables)")
        }
    }
}
