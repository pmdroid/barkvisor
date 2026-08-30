import GRDB

public struct M018_DropGuestAddressingJson: DatabaseMigration {
    public static let identifier = "M018_DropGuestAddressingJson"

    public static func migrate(_ db: GRDB.Database) throws {
        let columns = try db.columns(in: "vms").map(\.name)
        guard columns.contains("guestAddressingJson") else { return }
        try foldIntoSpecJSON(db)
        try db.execute(sql: "ALTER TABLE vms DROP COLUMN guestAddressingJson")
    }

    private static func foldIntoSpecJSON(_ db: GRDB.Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, specJson, guestAddressingJson FROM vms")
        for row in rows {
            let id: String = row["id"]
            let specJson: String? = row["specJson"]
            let addressingJson: String? = row["guestAddressingJson"]
            guard let addressingJson,
                  !addressingJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let addressing = JSONColumnCoding.decode(GuestAddressing.self, from: addressingJson)
            else { continue }
            guard var spec = WorkloadSpecJSON.decode(specJson) else { continue }
            if spec.spec.networks.isEmpty {
                spec.spec.networks = [WorkloadNetwork(addressing: addressing)]
            } else if spec.spec.networks[0].addressing == nil {
                spec.spec.networks[0].addressing = addressing
            } else {
                continue
            }
            guard let encoded = WorkloadSpecJSON.encode(spec) else { continue }
            try db.execute(
                sql: "UPDATE vms SET specJson = ? WHERE id = ?",
                arguments: [encoded, id],
            )
        }
    }
}
