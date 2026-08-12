import GRDB

/// PAS-35: drop dead `isoId`/`vncPort`; add dual-write `specJson`/`specGeneration`.
///
/// Existing rows keep column values as source of truth. `specJson` is backfilled
/// from columns after the schema change.
public struct M002_WorkloadSpec: DatabaseMigration {
    public static let identifier = "M002_WorkloadSpec"

    public static func migrate(_ db: GRDB.Database) throws {
        try foldLegacyISOId(db)
        try db.alter(table: "vms") { t in
            t.add(column: "specJson", .text)
            t.add(column: "specGeneration", .integer).notNull().defaults(to: 1)
        }
        try db.execute(sql: "ALTER TABLE vms DROP COLUMN isoId")
        try db.execute(sql: "ALTER TABLE vms DROP COLUMN vncPort")
        try backfillSpecJSON(db)
    }

    private static func foldLegacyISOId(_ db: GRDB.Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, isoId, isoIds FROM vms")
        for row in rows {
            let id: String = row["id"]
            let isoId: String? = row["isoId"]
            let isoIds: String? = row["isoIds"]
            guard let isoId, !isoId.isEmpty else { continue }
            let existing = JSONColumnCoding.decodeArrayOrEmpty(String.self, from: isoIds)
            if existing.isEmpty {
                let encoded = JSONColumnCoding.encode([isoId])
                try db.execute(
                    sql: "UPDATE vms SET isoIds = ? WHERE id = ?",
                    arguments: [encoded, id],
                )
            }
        }
    }

    private static func backfillSpecJSON(_ db: GRDB.Database) throws {
        let vms = try VM.fetchAll(db)
        for var vm in vms {
            vm.syncSpecProjection(bumpGeneration: false)
            try vm.update(db)
        }
    }
}
