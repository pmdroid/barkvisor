import GRDB

/// PAS-86: TOTP enrollment, hashed recovery codes, and short-lived login challenges.
public struct M010_TOTP: DatabaseMigration {
    public static let identifier = "M010_TOTP"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "user_totp") { t in
            t.column("userId", .text).primaryKey().references("users", onDelete: .cascade)
            t.column("secret", .text)
            t.column("pendingSecret", .text)
            t.column("pendingCreatedAt", .text)
            t.column("enabledAt", .text)
            t.column("lastUsedCounter", .integer)
        }

        try db.create(table: "totp_recovery_codes") { t in
            t.primaryKey("id", .text)
            t.column("userId", .text).notNull().references("users", onDelete: .cascade)
            t.column("codeHash", .text).notNull()
            t.column("createdAt", .text).notNull()
            t.column("usedAt", .text)
        }
        try db.create(
            index: "idx_totp_recovery_codes_userId",
            on: "totp_recovery_codes",
            columns: ["userId"],
        )

        try db.create(table: "login_challenges") { t in
            t.primaryKey("id", .text)
            t.column("userId", .text).notNull().references("users", onDelete: .cascade)
            t.column("tokenHash", .text).notNull().unique()
            t.column("createdAt", .text).notNull()
            t.column("expiresAt", .text).notNull()
            t.column("consumedAt", .text)
            t.column("attempts", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "idx_login_challenges_userId", on: "login_challenges", columns: ["userId"])
    }
}
