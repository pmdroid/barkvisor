import GRDB

/// PAS-275: PCIe GPU attachments live on `vms.gpuDevices`.
/// Numbered M014 because this stack already used M013 for coding-session JSON.
public struct M014_GPUPassthrough: DatabaseMigration {
    public static let identifier = "M014_GPUPassthrough"

    public static func migrate(_ db: GRDB.Database) throws {
        try db.alter(table: "vms") { t in
            t.add(column: "gpuDevices", .text)
        }
    }
}
