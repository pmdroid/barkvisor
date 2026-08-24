import GRDB

/// Per-Device Ollama upstream settings. Home is authoritative; the legacy
/// `ollama.endpoint` / `ollama.api_key` row stays as a global fallback.
public struct M014_OllamaPerHostSettings: DatabaseMigration {
    public static let identifier = "M014_OllamaPerHostSettings"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "ollama_host_settings") { t in
            t.primaryKey("hostId", .text)
            t.column("endpoint", .text)
            t.column("apiKey", .text)
        }
    }
}
