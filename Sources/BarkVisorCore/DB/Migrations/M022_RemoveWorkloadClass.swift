import Foundation
import GRDB

public struct M022_RemoveWorkloadClass: DatabaseMigration {
    public static let identifier = "M022_RemoveWorkloadClass"

    public static func migrate(_ db: GRDB.Database) throws {
        let columns = try db.columns(in: "vms")
        guard columns.contains(where: { $0.name == "workloadClass" }) else { return }
        try db.execute(sql: "ALTER TABLE vms DROP COLUMN workloadClass")
    }
}
