import GRDB

/// PAS-258: opt-in start after Device boot. Default off so House appliances stay stopped.
public struct M011_StartOnBoot: DatabaseMigration {
    public static let identifier = "M011_StartOnBoot"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "startOnBoot", .boolean).notNull().defaults(to: false)
        }
    }
}
