import Foundation
import GRDB

// MARK: - Failure Handlers

extension VMLifecycleService {
    /// Resets a workload whose cloud-image clone failed: the partial destination and the
    /// generated seed are removed, the disk row goes back to `creating` so a retry re-clones it,
    /// and the VM lands in `error` — a state start and delete both accept, so the workload is
    /// never stranded behind a half-written disk.
    static func handleProvisionFailure(
        vmID: String,
        diskID: String,
        diskPath: String,
        db: DatabasePool,
        message: String,
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
            Log.vm.error("Provisioning failed for VM \(vmID): \(message)", vm: vmID)
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
