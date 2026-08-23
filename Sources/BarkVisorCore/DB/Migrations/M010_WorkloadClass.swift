import GRDB

/// PAS-268: create-time House vs Agent class. Columns remain source of truth.
public struct M010_WorkloadClass: DatabaseMigration {
    public static let identifier = "M010_WorkloadClass"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "workloadClass", .text).notNull().defaults(to: WorkloadClass.house.rawValue)
        }
    }
}
