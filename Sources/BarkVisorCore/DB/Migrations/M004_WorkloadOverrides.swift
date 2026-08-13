import GRDB

/// PAS-41: persist portable `overrides.linux` / `overrides.macos` bags.
public struct M004_WorkloadOverrides: DatabaseMigration {
    public static let identifier = "M004_WorkloadOverrides"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "overridesJson", .text)
        }
    }
}
