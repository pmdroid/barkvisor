import GRDB

public struct M023_WorkloadOperations: DatabaseMigration {
    public static let identifier = "M023_WorkloadOperations"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "workload_operations") { t in
            t.primaryKey("id", .text)
            t.column("attemptID", .text).notNull()
            t.column("workloadID", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("requestedGeneration", .integer).notNull()
            t.column("phase", .text).notNull()
            t.column("progress", .double).notNull().defaults(to: 0)
            t.column("status", .text).notNull()
            t.column("idempotencyKey", .text).notNull().unique()
            t.column("recoveryOutcome", .text)
            t.column("resultPayload", .text)
            t.column("error", .text)
            t.column("projectPath", .text)
            t.column("dataRestored", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
            t.column("finishedAt", .text)
        }
        try db.create(
            index: "idx_workload_operations_workload",
            on: "workload_operations",
            columns: ["workloadID", "kind", "status"],
        )
        try db.create(table: "workload_operation_attempts") { t in
            t.primaryKey("id", .text)
            t.column("operationID", .text).notNull()
            t.column("status", .text).notNull()
            t.column("createdAt", .text).notNull()
        }
        try db.create(table: "deployment_revisions") { t in
            t.primaryKey("id", .text)
            t.column("workloadID", .text).notNull()
            t.column("generation", .integer).notNull()
            t.column("status", .text).notNull()
            t.column("manifestJSON", .text).notNull()
            t.column("previousRevisionID", .text)
            t.column("dataCompatibility", .text).notNull()
            t.column("backupDecision", .text).notNull()
            t.column("operationID", .text)
            t.column("createdAt", .text).notNull()
            t.column("committedAt", .text)
        }
        try db.create(
            index: "idx_deployment_revisions_workload",
            on: "deployment_revisions",
            columns: ["workloadID", "status"],
        )
    }
}
