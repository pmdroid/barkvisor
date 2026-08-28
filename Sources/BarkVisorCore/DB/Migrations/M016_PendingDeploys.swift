import GRDB

public struct M016_PendingDeploys: DatabaseMigration {
    public static let identifier = "M016_PendingDeploys"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "pending_deploys") { t in
            t.column("vmId", .text).notNull().references("vms", onDelete: .cascade)
            t.column("imageId", .text).notNull()
            t.column("payload", .text).notNull()
            t.column("createdAt", .text).notNull()
            t.primaryKey(["vmId", "imageId"])
        }
        try db.create(
            index: "idx_pending_deploys_vmId",
            on: "pending_deploys",
            columns: ["vmId"],
            unique: true,
        )
    }
}
