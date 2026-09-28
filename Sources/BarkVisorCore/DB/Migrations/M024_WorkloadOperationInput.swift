import GRDB

/// BV-06: durable delete intent. `workload_operations` already stored completion output in
/// `resultPayload`; an operation also needs the request it was accepted for so a resumed
/// `vm.delete` needs no in-memory context. `inputPayload` is nullable and stays additive.
public struct M024_WorkloadOperationInput: DatabaseMigration {
    public static let identifier = "M024_WorkloadOperationInput"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "workload_operations") { t in
            t.add(column: "inputPayload", .text)
        }
    }
}
