import GRDB

public struct M018_ApplicationWorkloads: DatabaseMigration {
    public static let identifier = "M018_ApplicationWorkloads"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "kind", .text).notNull().defaults(to: WorkloadSpec.kindVirtualMachine)
            t.add(column: "runtime", .text)
            t.add(column: "runtimeWorkloadId", .text)
            t.add(column: "composeYaml", .text)
            t.add(column: "composeProject", .text)
        }
        try makeBootDiskIdNullable(db)
    }

    private static func makeBootDiskIdNullable(_ db: GRDB.Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try db.execute(sql: """
        ALTER TABLE vms ADD COLUMN bootDiskIdNullable TEXT REFERENCES disks(id) ON DELETE CASCADE
        """)
        try db.execute(sql: "UPDATE vms SET bootDiskIdNullable = bootDiskId")
        try db.execute(sql: "ALTER TABLE vms DROP COLUMN bootDiskId")
        try db.execute(sql: "ALTER TABLE vms RENAME COLUMN bootDiskIdNullable TO bootDiskId")
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
}
