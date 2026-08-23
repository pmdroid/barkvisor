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
        #expect(fetched?.workloadClass == "house")
        #expect(fetched?.startOnBoot == false)
    }

    @Test func `workloadClass round trip agent`() throws {
        let queue = try migratedQueue()
        let disk = Disk(
            id: "disk-cls", name: "boot", path: "/data/boot.qcow2",
            sizeBytes: 21_474_836_480, format: "qcow2", vmId: nil,
            autoCreated: false, status: "ready", createdAt: "2025-01-01T00:00:00Z",
        )
        try queue.write { db in try disk.insert(db) }
        let vm = VM(
            id: "vm-agent", name: "cage", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-cls", networkId: nil, cloudInitPath: nil,
            description: nil, bootOrder: "cd", displayResolution: "1280x800",
            additionalDiskIds: nil, uefi: true, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil,
            portForwards: nil, autoCreated: false, pendingChanges: false,
            workloadClass: "agent",
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )
        try queue.write { db in try vm.insert(db) }
        let fetched = try queue.read { db in try VM.fetchOne(db, key: "vm-agent") }
        #expect(fetched?.workloadClass == "agent")
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

    @Test func `m011 adds startOnBoot column default off`() throws {
        let queue = try migratedQueue()
        try queue.read { db in
            let columns = try db.columns(in: "vms").map(\.name)
            #expect(columns.contains("startOnBoot"))
        }
    }

    @Test func `m008 adds listening port columns on guest_info`() throws {
        let queue = try migratedQueue()
        try queue.read { db in
            let columns = try db.columns(in: "guest_info").map(\.name)
            #expect(columns.contains("listeningPorts"))
            #expect(columns.contains("portsCollectedAt"))
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

    // MARK: - PAS-175 orphan audit FKs

    @Test func `orphan audit apiKeyId fails M005 without repair`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pas-175-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("db.sqlite").path
        var seedConfig = Configuration()
        seedConfig.foreignKeysEnabled = false
        let seed = try DatabaseQueue(path: path, configuration: seedConfig)
        try seedThroughM004WithOrphanAuditLog(seed)
        try seed.close()

        var liveConfig = Configuration()
        liveConfig.foreignKeysEnabled = true
        let live = try DatabaseQueue(path: path, configuration: liveConfig)
        #expect(throws: DatabaseError.self) {
            try AppDatabase.makeMigrator().migrate(live)
        }
    }

    @Test func `orphan audit apiKeyId is repaired then M005 applies`() throws {
        let queue = try queueThroughM004WithOrphanAuditLog()
        try queue.write { db in
            try AppDatabase.repairOrphanAuditForeignKeys(db)
        }
        try AppDatabase.makeMigrator().migrate(queue)

        try queue.read { db in
            let apiKeyId = try String.fetchOne(
                db,
                sql: "SELECT apiKeyId FROM audit_log WHERE id = 1",
            )
            #expect(apiKeyId == nil)
            let columns = try db.columns(in: "vms").map(\.name)
            #expect(columns.contains("healthJson"))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(applied.contains(M007_RepairOrphanAuditFKs.identifier))
        }
    }

    @Test func `appDatabase migrate repairs orphans on a file database`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pas-175-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("db.sqlite").path
        var seedConfig = Configuration()
        seedConfig.foreignKeysEnabled = false
        let seed = try DatabaseQueue(path: path, configuration: seedConfig)
        try seedThroughM004WithOrphanAuditLog(seed)
        try seed.close()

        let database = try AppDatabase(path: path)
        try database.migrate()
        try database.pool.read { db in
            let orphans = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM audit_log
                WHERE apiKeyId IS NOT NULL
                  AND apiKeyId NOT IN (SELECT id FROM api_keys)
                """,
            )
            #expect(orphans == 0)
        }
    }

    @Test func `database open recovery ignores constraint errors`() {
        let constraint = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "FOREIGN KEY")
        #expect(DatabaseOpenRecovery.shouldRestoreFromBackup(constraint) == false)
        #expect(DatabaseOpenRecovery.shouldRestoreFromBackup(DatabaseError(resultCode: .SQLITE_CORRUPT)) == true)
        #expect(DatabaseOpenRecovery.shouldRestoreFromBackup(DatabaseError(resultCode: .SQLITE_NOTADB)) == true)
        #expect(DatabaseOpenRecovery.shouldRestoreFromBackup(NSError(domain: "x", code: 1)) == false)
    }

    private func queueThroughM004WithOrphanAuditLog() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        try seedThroughM004WithOrphanAuditLog(queue)
        return queue
    }

    private func seedThroughM004WithOrphanAuditLog(_ db: some DatabaseWriter) throws {
        var partial = DatabaseMigrator()
        partial.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        partial.registerMigration(M002_WorkloadSpec.identifier) { db in
            try M002_WorkloadSpec.migrate(db)
        }
        partial.registerMigration(M003_ArchitectureAwareTemplates.identifier) { db in
            try M003_ArchitectureAwareTemplates.migrate(db)
        }
        partial.registerMigration(M004_WorkloadOverrides.identifier) { db in
            try M004_WorkloadOverrides.migrate(db)
        }
        try partial.migrate(db)

        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO users (id, username, password, createdAt)
                VALUES ('user-1', 'admin', 'x', '2026-08-13T16:39:34Z')
                """,
            )
            try db.execute(
                sql: """
                INSERT INTO audit_log (
                    timestamp, userId, username, action, resourceType, resourceId,
                    resourceName, authMethod, apiKeyId
                ) VALUES (
                    '2026-08-13T16:39:34Z', 'user-1', 'admin', 'vm.create', 'vm',
                    'vm-1', 'Home Assistant', 'apikey',
                    '8518b0a4-7584-43c9-a11c-870c20f9e2d7'
                )
                """,
            )
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
