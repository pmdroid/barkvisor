import GRDB

public struct M023_PortClaims: DatabaseMigration {
    public static let identifier = "M023_PortClaims"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "port_claims") { table in
            table.column("operation_id", .text).notNull()
            table.column("workload_kind", .text).notNull()
            table.column("workload_id", .text).notNull()
            table.column("host_port", .integer).notNull()
            table.column("proto", .text).notNull()
            table.column("family", .text).notNull()
            table.column("bind_address", .text).notNull()
            table.column("exposure", .text).notNull()
            table.primaryKey([
                "operation_id", "workload_id", "host_port", "proto", "family", "bind_address",
            ])
        }
    }
}
