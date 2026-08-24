import GRDB

/// Templates may declare House vs Agent (Onyx Lite uses Agent for cage Ollama).
public struct M015_TemplateWorkloadClass: DatabaseMigration {
    public static let identifier = "M015_TemplateWorkloadClass"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vm_templates") { t in
            t.add(column: "workloadClass", .text)
        }
    }
}
