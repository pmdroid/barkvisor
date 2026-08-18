import GRDB

/// PAS-225: persist guest TCP LISTEN snapshot on `guest_info`.
/// `listeningPorts` is JSON (`[]` = none, NULL = unavailable).
public struct M008_GuestListeningPorts: DatabaseMigration {
    public static let identifier = "M008_GuestListeningPorts"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "guest_info") { t in
            t.add(column: "listeningPorts", .text)
            t.add(column: "portsCollectedAt", .text)
        }
    }
}
