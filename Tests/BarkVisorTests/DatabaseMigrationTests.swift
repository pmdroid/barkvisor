import GRDB
import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

final class DatabaseMigrationTests: XCTestCase {
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

    func testAllMigrationsRunWithoutError() throws {
        XCTAssertNoThrow(try migratedQueue())
    }

    func testMigrationsAreIdempotent() throws {
        let queue = try migratedQueue()
        // Running migrations again should be a no-op
        XCTAssertNoThrow(try makeInMemoryMigrator().migrate(queue))
    }

    // MARK: - VM Round Trip

    func testVMRoundTrip() throws {
        let queue = try migratedQueue()

        // Insert a disk first to satisfy the foreign key constraint
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

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "test")
        XCTAssertEqual(fetched?.vmType, "linux-arm64")
        XCTAssertEqual(fetched?.cpuCount, 2)
        XCTAssertEqual(fetched?.memoryMb, 1_024)
        XCTAssertEqual(fetched?.macAddress, "52:54:00:12:34:56")
    }

    // MARK: - Disk Round Trip

    func testDiskRoundTrip() throws {
        let queue = try migratedQueue()
        let disk = Disk(
            id: "disk-1", name: "boot", path: "/data/boot.qcow2",
            sizeBytes: 21_474_836_480, format: "qcow2", vmId: nil,
            autoCreated: false, status: "ready", createdAt: "2025-01-01T00:00:00Z",
        )

        try queue.write { db in try disk.insert(db) }
        let fetched = try queue.read { db in try Disk.fetchOne(db, key: "disk-1") }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "boot")
        XCTAssertEqual(fetched?.sizeBytes, 21_474_836_480)
        XCTAssertEqual(fetched?.format, "qcow2")
    }

    // MARK: - Network Round Trip

    func testNetworkRoundTrip() throws {
        let queue = try migratedQueue()
        let network = Network(
            id: "net-1", name: "default", mode: "nat", bridge: nil,
            macAddress: nil, dnsServer: "8.8.8.8",
            autoCreated: true, isDefault: true,
        )

        try queue.write { db in try network.insert(db) }
        let fetched = try queue.read { db in try Network.fetchOne(db, key: "net-1") }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "default")
        XCTAssertEqual(fetched?.mode, "nat")
        XCTAssertEqual(fetched?.dnsServer, "8.8.8.8")
        XCTAssertEqual(fetched?.isDefault, true)
    }

    // MARK: - Tables Exist

    func testExpectedTablesExist() throws {
        let queue = try migratedQueue()
        let tables = try queue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'grdb_%' ORDER BY name",
            )
        }

        let expected = [
            "api_keys",
            "app_settings",
            "audit_log",
            "bridges",
            "disks",
            "guest_info",
            "image_repositories",
            "images",
            "networks",
            "repository_images",
            "ssh_keys",
            "tus_uploads",
            "users",
            "vm_templates",
            "vms",
        ]
        for table in expected {
            XCTAssert(tables.contains(table), "Expected table '\(table)' to exist, got: \(tables)")
        }
    }
}
