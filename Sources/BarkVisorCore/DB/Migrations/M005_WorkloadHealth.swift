import GRDB

/// PAS-65: persist VM HTTP/TCP health-check config (Linear `spec.health`).
/// Source of truth is the column. `specJson` is read by EffectiveWorkloadPipeline.
public struct M005_WorkloadHealth: DatabaseMigration {
    public static let identifier = "M005_WorkloadHealth"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "healthJson", .text)
        }
    }
}
