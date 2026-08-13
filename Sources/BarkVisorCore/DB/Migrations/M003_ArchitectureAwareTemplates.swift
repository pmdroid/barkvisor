import GRDB

/// PAS-33: per-arch template metadata (architectures, image map, min RAM, features).
public struct M003_ArchitectureAwareTemplates: DatabaseMigration {
    public static let identifier = "M003_ArchitectureAwareTemplates"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vm_templates") { t in
            t.add(column: "architecturesJson", .text)
            t.add(column: "minMemoryMB", .integer)
            t.add(column: "requiredFeaturesJson", .text)
            t.add(column: "imageByArchJson", .text)
        }
    }
}
