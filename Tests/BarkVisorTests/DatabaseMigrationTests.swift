import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite struct DatabaseMigrationTests {
    private func makeInMemoryMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        return migrator
    }

    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try makeInMemoryMigrator().migrate(queue)
        return queue
    }

    // MARK: - Migration Integrity

    @Test func allMigrationsRunWithoutError() throws {
        #expect(throws: Never.self) { try migratedQueue() }
    }

    @Test func migrationsAreIdempotent() throws {
        let queue = try migratedQueue()
        #expect(throws: Never.self) { try makeInMemoryMigrator().migrate(queue) }
    }

    // MARK: - VM Round Trip

    @Test func vmRoundTrip() throws {
        let queue = try migratedQueue()

        let disk = Disk(
            id: "disk-1", name: "boot", path: "/data/boot.qcow2",
            sizeBytes: 21_474_836_480, format: "qcow2", vmId: nil,
            autoCreated: false, status: "ready", createdAt: "2025-01-01T00:00:00Z",
        )
        try queue.write { db in try disk.insert(db) }

        let vm = VM(
            id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-1",
            isoId: nil, networkId: nil, cloudInitPath: nil, vncPort: nil,
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

    @Test func diskRoundTrip() throws {
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

    @Test func networkRoundTrip() throws {
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

    // MARK: - Tables Exist

    @Test func expectedTablesExist() throws {
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
