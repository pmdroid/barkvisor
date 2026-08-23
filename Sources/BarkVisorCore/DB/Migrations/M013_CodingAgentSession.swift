import GRDB

/// PAS-273: coding-session TTL, receipt, and reset live on `vms.sessionJson`.
public struct M013_CodingAgentSession: DatabaseMigration {
    public static let identifier = "M013_CodingAgentSession"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "sessionJson", .text)
        }
    }
}
