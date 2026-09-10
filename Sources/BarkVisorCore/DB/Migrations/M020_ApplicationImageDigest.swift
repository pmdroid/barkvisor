import GRDB

public struct M020_ApplicationImageDigest: DatabaseMigration {
    public static let identifier = "M020_ApplicationImageDigest"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "imageRef", .text)
            t.add(column: "digest", .text)
            t.add(column: "catalogDigest", .text)
            t.add(column: "volumeRootsJson", .text)
        }
    }
}
