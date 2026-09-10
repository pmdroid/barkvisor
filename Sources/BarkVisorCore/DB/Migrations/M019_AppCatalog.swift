import GRDB

public struct M019_AppCatalog: DatabaseMigration {
    public static let identifier = "M019_AppCatalog"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "app_catalog") { t in
            t.primaryKey("id", .text)
            t.column("repositoryId", .text).notNull()
                .references("image_repositories", onDelete: .cascade)
            t.column("slug", .text).notNull()
            t.column("name", .text).notNull()
            t.column("tagline", .text)
            t.column("description", .text)
            t.column("iconUrl", .text)
            t.column("category", .text).notNull()
            t.column("archesJson", .text)
            t.column("source", .text).notNull()
            t.column("composeYaml", .text).notNull()
            t.column("envSchemaJson", .text)
            t.column("volumesJson", .text)
            t.column("portsJson", .text)
            t.column("image", .text)
            t.column("digest", .text)
            t.column("unsupportedReasonsJson", .text)
            t.column("uiJson", .text)
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        try db.create(
            index: "idx_app_catalog_repo_slug",
            on: "app_catalog",
            columns: ["repositoryId", "slug"],
            unique: true,
        )
    }
}
