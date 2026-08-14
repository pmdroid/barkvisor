import GRDB

/// Null `audit_log` foreign keys that no longer resolve.
///
/// Older builds deleted `api_keys` (and sometimes users) while SQLite foreign
/// keys were off, so `ON DELETE SET NULL` never ran. GRDB then fails the
/// next migration (`M005_WorkloadHealth` and later) with SQLITE_CONSTRAINT.
///
/// Registered as M007 because main already shipped `M006_ImageSha256`.
/// The pre-migrate hook in `AppDatabase.migrate()` still runs first so
/// M005 can apply on files that never recorded this identifier.
public struct M007_RepairOrphanAuditFKs: DatabaseMigration {
    public static let identifier = "M007_RepairOrphanAuditFKs"

    public static func migrate(_ db: GRDB.Database) throws {
        try AppDatabase.repairOrphanAuditForeignKeys(db)
    }
}
