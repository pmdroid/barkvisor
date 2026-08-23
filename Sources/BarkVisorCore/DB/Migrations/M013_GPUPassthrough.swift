import GRDB

/// PAS-275: PCIe GPU attachments live on `vms.gpuDevices`.
public struct M013_GPUPassthrough: DatabaseMigration {
    public static let identifier = "M013_GPUPassthrough"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "gpuDevices", .text)
        }
    }
}
