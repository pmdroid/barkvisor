import GRDB

/// PAS-242: opaque refresh tokens (hashed) and one-at-a-time login QR offers.
public struct M009_AuthSessions: DatabaseMigration {
    public static let identifier = "M009_AuthSessions"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "refresh_tokens") { t in
            t.primaryKey("id", .text)
            t.column("userId", .text).notNull().references("users", onDelete: .cascade)
            t.column("familyId", .text).notNull()
            t.column("tokenHash", .text).notNull().unique()
            t.column("createdAt", .text).notNull()
            t.column("expiresAt", .text).notNull()
            t.column("usedAt", .text)
            t.column("revokedAt", .text)
        }
        try db.create(index: "idx_refresh_tokens_familyId", on: "refresh_tokens", columns: ["familyId"])
        try db.create(index: "idx_refresh_tokens_userId", on: "refresh_tokens", columns: ["userId"])

        try db.create(table: "login_offers") { t in
            t.primaryKey("id", .text)
            t.column("userId", .text).notNull().references("users", onDelete: .cascade)
            t.column("codeHash", .text).notNull().unique()
            t.column("codeDisplay", .text).notNull()
            t.column("host", .text).notNull()
            t.column("port", .integer).notNull()
            t.column("createdAt", .text).notNull()
            t.column("expiresAt", .text).notNull()
            t.column("consumedAt", .text)
        }
    }
}
