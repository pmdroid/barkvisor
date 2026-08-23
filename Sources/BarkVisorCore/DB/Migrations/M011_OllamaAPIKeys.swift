import GRDB

/// PAS-269: inference tokens are a kind of API key, not a second auth stack.
public struct M011_OllamaAPIKeys: DatabaseMigration {
    public static let identifier = "M011_OllamaAPIKeys"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "api_keys") { t in
            t.add(column: "kind", .text).notNull().defaults(to: APIKeyKind.full.rawValue)
        }
    }
}
