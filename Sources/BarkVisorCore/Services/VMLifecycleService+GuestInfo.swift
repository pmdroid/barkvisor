import Foundation
import GRDB

// MARK: - Failure Handlers

extension VMLifecycleService {
    static func handleProvisionFailure(
        vmID: String,
        diskID: String,
        diskPath: String,
        db: DatabasePool,
        error: Error,
    ) async {
        try? FileManager.default.removeItem(atPath: diskPath)
        try? FileManager.default.removeItem(
            at: Config.dataDir.appendingPathComponent("cloud-init/\(vmID)"),
        )

        let now = iso8601.string(from: Date())
        do {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE vms SET state = 'error', cloudInitPath = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [now, vmID],
                )
                try db.execute(
                    sql: "UPDATE disks SET status = 'creating' WHERE id = ?",
                    arguments: [diskID],
                )
            }
            Log.vm.error("Provisioning failed for VM \(vmID): \(error)", vm: vmID)
        } catch {
            Log.vm.error("Failed to mark provisioning failure for VM \(vmID): \(error)", vm: vmID)
        }
    }

    static func handleDeleteFailure(
        vmID: String,
        db: DatabasePool,
        error: Error,
    ) async {
        let now = iso8601.string(from: Date())
        do {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE vms SET state = 'error', updatedAt = ? WHERE id = ?",
                    arguments: [now, vmID],
                )
            }
            Log.vm.error("VM deletion failed for \(vmID): \(error)", vm: vmID)
        } catch {
            Log.vm.error("Failed to mark delete failure for VM \(vmID): \(error)", vm: vmID)
        }
    }
}
