import GRDB

public struct M015_Passkeys: DatabaseMigration {
    public static let identifier = "M015_Passkeys"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "passkeys") { t in
            t.primaryKey("id", .text)
            t.column("userId", .text).notNull().references("users", onDelete: .cascade)
            t.column("credentialId", .text).notNull().unique()
            t.column("publicKey", .blob).notNull()
            t.column("signCount", .integer).notNull().defaults(to: 0)
            t.column("name", .text).notNull()
            t.column("createdAt", .text).notNull()
            t.column("lastUsedAt", .text)
            t.column("transports", .text)
        }
        try db.create(index: "idx_passkeys_userId", on: "passkeys", columns: ["userId"])
    }
}
