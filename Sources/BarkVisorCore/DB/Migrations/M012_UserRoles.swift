import GRDB

/// PAS-286: admin | inference on the user. Existing rows stay admin.
public struct M012_UserRoles: DatabaseMigration {
    public static let identifier = "M012_UserRoles"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "users") { t in
            t.add(column: "role", .text).notNull().defaults(to: UserRole.admin.rawValue)
        }
    }
}
