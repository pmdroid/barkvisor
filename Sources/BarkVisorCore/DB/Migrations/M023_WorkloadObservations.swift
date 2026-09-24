import Foundation
import GRDB

public struct M023_WorkloadObservations: DatabaseMigration {
    public static let identifier = "M023_WorkloadObservations"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "workload_observations", ifNotExists: true) { t in
            t.primaryKey("id", .text).references("vms", onDelete: .cascade)
            t.column("sequence", .integer).notNull()
            t.column("appliedGeneration", .integer).notNull()
            t.column("runtimeIdentity", .text)
            t.column("processState", .text).notNull()
            t.column("readiness", .text).notNull()
            t.column("condition", .text).notNull()
            t.column("observedAt", .text).notNull()
            t.column("error", .text)
            t.column("freshness", .text).notNull()
            t.column("enforcedCpu", .integer)
            t.column("enforcedMemoryMb", .integer)
            t.column("servicesJson", .text)
        }
        try db.execute(sql: """
        INSERT INTO workload_observations (
            id, sequence, appliedGeneration, runtimeIdentity, processState,
            readiness, condition, observedAt, error, freshness,
            enforcedCpu, enforcedMemoryMb, servicesJson
        )
        SELECT
            id, 1, specGeneration, runtimeWorkloadId, state,
            'unknown', 'unknown', updatedAt, NULL, 'unknown',
            NULL, NULL, NULL
        FROM vms
        WHERE NOT EXISTS (
            SELECT 1 FROM workload_observations WHERE workload_observations.id = vms.id
        )
        """)
    }
}
