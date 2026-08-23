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
        // Do not VM.fetchAll: later columns (workloadClass, startOnBoot) are missing here.
        let columns = try Set(db.columns(in: "vms").map(\.name))
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM vms")
        for row in rows {
            var vm = VM(
                id: row["id"],
                name: row["name"],
                vmType: row["vmType"],
                state: row["state"],
                cpuCount: row["cpuCount"],
                memoryMb: row["memoryMb"],
                bootDiskId: row["bootDiskId"],
                isoIds: row["isoIds"],
                networkId: row["networkId"],
                cloudInitPath: row["cloudInitPath"],
                description: row["description"],
                bootOrder: row["bootOrder"],
                displayResolution: row["displayResolution"],
                additionalDiskIds: row["additionalDiskIds"],
                uefi: row["uefi"],
                tpmEnabled: row["tpmEnabled"],
                macAddress: row["macAddress"],
                sharedPaths: row["sharedPaths"],
                portForwards: row["portForwards"],
                usbDevices: columns.contains("usbDevices") ? row["usbDevices"] : nil,
                autoCreated: row["autoCreated"],
                pendingChanges: row["pendingChanges"],
                specJson: columns.contains("specJson") ? row["specJson"] : nil,
                overridesJson: columns.contains("overridesJson") ? row["overridesJson"] : nil,
                healthJson: columns.contains("healthJson") ? row["healthJson"] : nil,
                workloadClass: columns.contains("workloadClass") ? row["workloadClass"] : WorkloadClass.house.rawValue,
                specGeneration: columns.contains("specGeneration") ? (row["specGeneration"] ?? 1) : 1,
                startOnBoot: columns.contains("startOnBoot") ? (row["startOnBoot"] ?? false) : false,
                createdAt: row["createdAt"],
                updatedAt: row["updatedAt"],
            )
            vm.syncSpecProjection(bumpGeneration: false)
            try db.execute(
                sql: "UPDATE vms SET specJson = ? WHERE id = ?",
                arguments: [vm.specJson, vm.id],
            )
        }
    }
}
