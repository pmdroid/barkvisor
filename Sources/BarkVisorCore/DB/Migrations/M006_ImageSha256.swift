import GRDB

/// PAS-176 slice B pr1: persist sha256 of the stored Library file on `images`.
/// Enough integrity for depot verify later. Not full CAS (PAS-36).
public struct M006_ImageSha256: DatabaseMigration {
    public static let identifier = "M006_ImageSha256"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "images") { t in
            t.add(column: "sha256", .text)
        }
    }
}
