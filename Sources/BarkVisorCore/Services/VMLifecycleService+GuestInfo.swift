import Foundation
import GRDB

// MARK: - Failure Handlers

extension VMLifecycleService {
    /// Resets a workload whose cloud-image clone failed: the disk row goes back to `creating` so
    /// a retry re-clones it, the VM lands in `error` — a state start and delete both accept, so the
    /// workload is never stranded behind a half-written disk — and the operation record closes so
    /// the failure is not repeated on every restart.
    ///
    /// The claim check and **every row write share one transaction**. Checking separately first
    /// would be a TOCTOU: a delete committing `deleting` between the check and the write would
    /// still be overwritten, resurrecting a workload mid-teardown and clearing the cloud-init
    /// path that teardown still owns.
    ///
    /// Returns `false` — writing nothing, releasing no seed, keeping the template marker — when
    /// the attempt no longer owns the claim: a delete has taken the row, or a newer attempt has
    /// superseded this one. In that case the delete's `deleting` state, its seed release, and its
    /// disk removal are authoritative and must stand.
    @discardableResult
    static func handleProvisionFailure(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        outcome: String,
        message: String,
    ) async -> Bool {
        let vmID = record.workloadID
        let diskID = record.provisionIntent?.diskID
        let now = iso8601.string(from: Date())
        do {
            let applied = try await db.write { db -> Bool in
                guard let vm = try VM.fetchOne(db, key: vmID), vm.state != "deleting" else {
                    return false
                }
                guard var op = try WorkloadOperationRecord.fetchOne(db, key: record.id) else {
                    return false
                }
                guard op.attemptID == record.attemptID, op.isOpen else { return false }
                try db.execute(
                    sql: "UPDATE vms SET state = 'error', cloudInitPath = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [now, vmID],
                )
                if let diskID, !diskID.isEmpty {
                    try db.execute(
                        sql: "UPDATE disks SET status = 'creating' WHERE id = ?",
                        arguments: [diskID],
                    )
                }
                op.status = WorkloadOperationStatus.failed
                op.recoveryOutcome = outcome
                op.error = message
                op.updatedAt = now
                op.finishedAt = now
                try op.update(db)
                // The template deploy's resume marker goes in the same transaction as the state
                // change it describes. Left behind after a lost claim it is inert: the workload
                // row is going away, and `resumePending` skips rows with no VM behind them.
                try PendingDeploy.filter(PendingDeploy.Columns.vmId == vmID).deleteAll(db)
                return true
            }
            guard applied else {
                Log.vm.warning(
                    "Provisioning failure for VM \(vmID) not applied: the row is no longer this attempt's",
                    vm: vmID,
                )
                return false
            }
            // Only once the reset has committed is the generated seed ours to release.
            try? FileManager.default.removeItem(
                at: Config.dataDir.appendingPathComponent("cloud-init/\(vmID)"),
            )
            Log.vm.error("Provisioning failed for VM \(vmID): \(message)", vm: vmID)
            return true
        } catch {
            Log.vm.error("Failed to mark provisioning failure for VM \(vmID): \(error)", vm: vmID)
            return false
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
