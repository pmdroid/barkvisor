import Foundation
import GRDB

// MARK: - Durable VM provisioning (BV-07)

/// Test seam over the disk-level work a provision performs. Production leaves these unset and
/// goes through `DiskService`; a test substitutes a fake clone so the interruption points — a
/// half-written destination, a clone that never started — can be driven without `qemu-img` on
/// the host, and so "how many times was this cloned?" is observable.
public enum VMProvisionEffects {
    @TaskLocal public static var clone: (@Sendable (String, URL, Int?) throws -> Void)?
    @TaskLocal public static var virtualSize: (@Sendable (URL) throws -> Int64)?
    @TaskLocal public static var destinationComplete: (@Sendable (URL) -> Bool)?
}

/// Drives a cloud-image clone through durable phases so an interrupted provision resumes on the
/// next startup instead of stranding the workload in `provisioning` with a half-written disk.
///
/// Phases: `accepted → cloning → disk_ready → finalised`.
///
/// **Resume decision: a partially-written destination is discarded and re-cloned from zero, never
/// resumed in place.** `qemu-img convert` exposes no resumable offset, and a truncated qcow2 has
/// an unusable header and refcount table, so there is no correct way to continue a partial write.
/// "Resume" therefore means *re-run the clone from the immutable source image*, which is safe
/// because the source is the Library's own image and the destination is a fresh per-workload
/// path. The cost is a full re-clone of a large image after a crash; the alternative would risk
/// booting a corrupt disk. Once the clone is checkpointed `disk_ready` the destination is trusted
/// and never rewritten.
///
/// Every step is idempotent. Re-running a phase after a crash has no adverse second effect:
/// removing a partial destination is a no-op on a missing path, the clone is a deterministic
/// function of the source, and finalisation is a pair of plain row updates.
public enum VMProvision {
    public static let phaseAccepted = "accepted"
    public static let phaseCloning = "cloning"
    public static let phaseDiskReady = "disk_ready"
    public static let phaseFinalised = "finalised"

    public static let outcomeProvisioned = "disk_provisioned"
    public static let outcomeSourceMissing = "source_image_missing"
    public static let outcomeWorkloadMissing = "workload_missing"
    public static let outcomeUnresumable = "provision_unresumable"
    public static let outcomeIncomplete = "provision_incomplete"

    /// Ordered so a resumed provision knows which phases still need work.
    static let phaseRank: [String: Int] = [
        phaseAccepted: 0,
        phaseCloning: 1,
        phaseDiskReady: 2,
        phaseFinalised: 3,
    ]

    public static func isInterruption(_ error: Error) -> Bool {
        error is WorkloadOperationInterrupted || error is CancellationError
    }

    // MARK: - In-memory path

    /// Drives the provision for a live request, reporting progress onto the background task.
    public static func run(
        operationID: String,
        attemptID: String,
        backgroundTasks: BackgroundTaskManager,
        taskID: String,
        db: DatabasePool,
    ) async throws {
        guard let stored = try await WorkloadOperationStore.fetch(db: db, id: operationID) else {
            throw BarkVisorError.notFound("Provision operation \(operationID) not found")
        }
        // Drive the attempt this request owns. If a newer attempt has already taken over, the
        // superseded worker must not touch the record.
        let record = stored.attemptID == attemptID ? stored : rebound(stored, attemptID: attemptID)
        try await drive(record: record, db: db) { value in
            await backgroundTasks.reportProgress(taskID, progress: value)
        }
    }

    // MARK: - Startup recovery

    /// Resumes a `vm.provision` record left open by a crash. Safe when the workload row is
    /// already gone or is being deleted: the record is completed instead.
    public static func recover(
        record: WorkloadOperationRecord,
        db: DatabasePool,
    ) async throws {
        try await drive(record: record, db: db, report: nil)
    }

    // MARK: - Phase driver

    static func drive(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        report: (@Sendable (Double) async -> Void)?,
    ) async throws {
        do {
            try await runPhases(record: record, db: db, report: report)
        } catch {
            // An interruption must leave the record open and the row `provisioning` so the next
            // startup picks it up. A real failure closes the record and resets the row.
            if !isInterruption(error) {
                await failProvision(record: record, db: db, message: error.localizedDescription)
            }
            throw error
        }
    }

    private static func runPhases(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        report: (@Sendable (Double) async -> Void)?,
    ) async throws {
        guard let intent = record.provisionIntent else {
            // A record with no stored intent cannot be resumed safely, and guessing would be
            // worse than failing: the workload must be re-created from its image. Closing the
            // record also means nothing owns the row's `provisioning` state any more, so the row
            // is released here rather than left with no resumption handle at all.
            await failProvision(
                record: record,
                db: db,
                outcome: outcomeUnresumable,
                message: "Provision record has no stored clone intent; re-create the workload from its image",
            )
            return
        }

        var phase = try await currentPhase(operation: record, db: db)
        if rank(phase) >= rank(phaseFinalised) {
            try await finish(record: record, db: db)
            return
        }

        // The row may be gone (deleted mid-provision) or claimed by a delete. Either way there is
        // nothing left to provision and nothing to reset.
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: record.workloadID) }),
              vm.state != "deleting"
        else {
            _ = try await WorkloadOperationStore.complete(
                db: db,
                operationID: record.id,
                attemptID: record.attemptID,
                phase: phaseFinalised,
                recoveryOutcome: outcomeWorkloadMissing,
                resultPayload: record.workloadID,
            )
            return
        }

        if phase == phaseAccepted {
            try gate(phaseAccepted)
        }

        let destination = URL(fileURLWithPath: intent.destinationPath)
        if rank(phase) < rank(phaseDiskReady) {
            // The destination is absent or partial: throw it away and clone from the source again.
            guard sourceIsUsable(intent.sourceImagePath) else {
                try await failSourceMissing(record: record, intent: intent, db: db)
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try await checkpoint(
                record: record, db: db, phase: phaseCloning, progress: 0.2, report: report,
            )
            phase = phaseCloning
            try performClone(intent: intent, destination: destination)
            try await discardIfClaimLost(record: record, destination: destination, db: db)
            try await checkpoint(
                record: record, db: db, phase: phaseDiskReady, progress: 0.7, report: report,
            )
            phase = phaseDiskReady
        } else if !destinationIsComplete(destination) {
            // The clone was checkpointed done but the destination is gone or unreadable — a file
            // the person removed, or a write that did not survive. Re-clone rather than boot it.
            guard sourceIsUsable(intent.sourceImagePath) else {
                try await failSourceMissing(record: record, intent: intent, db: db)
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try await checkpoint(
                record: record, db: db, phase: phaseCloning, progress: 0.4, report: report,
            )
            try performClone(intent: intent, destination: destination)
            try await discardIfClaimLost(record: record, destination: destination, db: db)
            try await checkpoint(
                record: record, db: db, phase: phaseDiskReady, progress: 0.7, report: report,
            )
            phase = phaseDiskReady
        }

        if rank(phase) < rank(phaseFinalised) {
            guard try finalise(record: record, intent: intent, vm: vm, db: db) else {
                // A delete claimed the row while the clone was running. Nothing was written, so
                // the delete's `deleting` state and its disk removal stand.
                throw WorkloadOperationInterrupted()
            }
            try await checkpoint(
                record: record, db: db, phase: phaseFinalised, progress: 0.95, report: report,
            )
        }
        try await finish(record: record, db: db)
        await report?(1)
    }

    /// Whether this attempt may still write the workload's rows: its record is open and owned by
    /// this attempt, and no delete has claimed the row.
    ///
    /// `deleting` is the only state from which a delete proceeds to remove the disk, so it is the
    /// one state that must never be overwritten. `provisioning` and `error` are both legitimate: a
    /// first run is `provisioning`, and a retry after a failed clone drives a row the failure
    /// handler already moved to `error`.
    private static func ownsClaim(record: WorkloadOperationRecord, db: DatabasePool) async throws -> Bool {
        let vmID = record.workloadID
        return try await db.read { db in
            guard let row = try VM.fetchOne(db, key: vmID) else { return false }
            guard row.state != "deleting" else { return false }
            guard let op = try WorkloadOperationRecord.fetchOne(db, key: record.id) else { return false }
            return op.attemptID == record.attemptID && op.isOpen
        }
    }

    /// A delete that claimed the row cannot stop `qemu-img` — `cloneAndResize` is a synchronous
    /// subprocess, so cancelling the task does not interrupt it. The clone therefore outlives the
    /// delete's disk removal, and whichever side runs last must clean up. This is the clone side:
    /// the file this attempt created is removed here rather than left orphaned next to a disk row
    /// that no longer exists.
    private static func discardIfClaimLost(
        record: WorkloadOperationRecord,
        destination: URL,
        db: DatabasePool,
    ) async throws {
        guard try await ownsClaim(record: record, db: db) == false else { return }
        try? FileManager.default.removeItem(at: destination)
        throw WorkloadOperationInterrupted()
    }

    /// Writes the rows the workload needs once the clone is on disk: the disk becomes `ready`
    /// with its real virtual size, and the VM leaves `provisioning` for `stopped` with a
    /// regenerated cloud-init seed when the intent asked for one.
    ///
    /// Returns `false` — writing nothing — when a delete claimed the row while the clone was
    /// running. The claim check and both writes share one transaction, so a delete that lands
    /// between them cannot be undone by a stale `stopped` write that would advertise a disk the
    /// delete is removing as startable.
    private static func finalise(
        record: WorkloadOperationRecord,
        intent: WorkloadProvisionIntent,
        vm: VM,
        db: DatabasePool,
    ) throws -> Bool {
        let sizeBytes = try readVirtualSize(URL(fileURLWithPath: intent.destinationPath))
        let ciPath = try cloudInitPath(intent: intent, vm: vm)
        let now = iso8601.string(from: Date())
        let diskID = intent.diskID
        let vmID = record.workloadID
        let attemptID = record.attemptID
        let operationID = record.id
        let committed = try db.write { db -> Bool in
            guard let row = try VM.fetchOne(db, key: vmID), row.state != "deleting" else {
                return false
            }
            guard let op = try WorkloadOperationRecord.fetchOne(db, key: operationID) else {
                return false
            }
            guard op.attemptID == attemptID, op.isOpen else { return false }
            try db.execute(
                sql: "UPDATE disks SET status = 'ready', sizeBytes = ? WHERE id = ?",
                arguments: [sizeBytes, diskID],
            )
            if let ciPath {
                try db.execute(
                    sql: "UPDATE vms SET state = 'stopped', cloudInitPath = ?, updatedAt = ? WHERE id = ?",
                    arguments: [ciPath, now, vmID],
                )
            } else {
                try db.execute(
                    sql: "UPDATE vms SET state = 'stopped', updatedAt = ? WHERE id = ?",
                    arguments: [now, vmID],
                )
            }
            return true
        }
        // A seed written for a claim we no longer hold would be an orphan directory.
        if !committed, ciPath != nil {
            try? FileManager.default.removeItem(
                at: Config.dataDir.appendingPathComponent("cloud-init/\(vmID)"),
            )
        }
        return committed
    }

    private static func cloudInitPath(intent: WorkloadProvisionIntent, vm: VM) throws -> String? {
        guard intent.hasCloudInit else { return nil }
        return try CloudInitService.generateISO(
            vmID: vm.id,
            vmName: intent.vmName.isEmpty ? vm.name : intent.vmName,
            sshKeys: intent.sshAuthorizedKeys,
            userData: intent.userData,
            instanceID: vm.id,
            macAddress: vm.macAddress,
        ).path
    }

    // MARK: - Verification

    /// The source is the Library's own image, so a readable, non-empty file is a usable source.
    static func sourceIsUsable(_ path: String) -> Bool {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
        return size > 0
    }

    /// A destination is only trusted once `qemu-img` can read an image header out of it.
    static func destinationIsComplete(_ destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        if let override = VMProvisionEffects.destinationComplete { return override(destination) }
        return DiskService.verifyClonedImage(path: destination.path)
    }

    // MARK: - Disk work

    private static func performClone(intent: WorkloadProvisionIntent, destination: URL) throws {
        if let clone = VMProvisionEffects.clone {
            try clone(intent.sourceImagePath, destination, intent.sizeGB)
            return
        }
        try DiskService.cloneAndResize(
            sourcePath: intent.sourceImagePath,
            destPath: destination,
            sizeGB: intent.sizeGB,
        )
    }

    private static func readVirtualSize(_ destination: URL) throws -> Int64 {
        if let size = VMProvisionEffects.virtualSize { return try size(destination) }
        return try DiskService.getVirtualSize(path: destination.path)
    }

    // MARK: - Failure

    private static func failSourceMissing(
        record: WorkloadOperationRecord,
        intent: WorkloadProvisionIntent,
        db: DatabasePool,
    ) async {
        // The clone can never succeed without its source, so reset the row rather than leaving it
        // `provisioning` with nothing left to try.
        await failProvision(
            record: record,
            db: db,
            outcome: outcomeSourceMissing,
            message: "Source image \(intent.sourceImagePath) is missing; re-create the workload from its image",
        )
    }

    /// Removes the partial destination and resets the workload to `error` so start and delete both
    /// work again. The record closes retryable: a retry re-runs the clone from the same source.
    ///
    /// The destination removal is the one cleanup that stays unconditional, and deliberately so: it
    /// is the file *this* attempt created, the delete removes that same path, and removing it is
    /// what stops a clone that lost its claim from orphaning a disk. Everything else — the row
    /// state, the seed release, the disk reset, the template marker — belongs to whoever holds the
    /// claim now, and `handleProvisionFailure` applies all of it in a single transaction guarded by
    /// that claim.
    private static func failProvision(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        outcome: String = outcomeIncomplete,
        message: String,
    ) async {
        if let intent = record.provisionIntent {
            try? FileManager.default.removeItem(atPath: intent.destinationPath)
        }
        await VMLifecycleService.handleProvisionFailure(
            record: record, db: db, outcome: outcome, message: message,
        )
    }

    // MARK: - Template marker

    /// A template deploy keeps its `pending_deploys` row for the whole clone window and clears it
    /// only once the durable operation reaches a terminal state. Without this, a crash between
    /// the lifecycle call and the clone would leave no resume marker at all.
    private static func settleTemplateMarker(vmID: String, failure: String?, db: DatabasePool) async {
        await TemplateDeployService.settlePending(vmID: vmID, failure: failure, db: db)
    }

    // MARK: - Checkpoints

    private static func checkpoint(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        phase: String,
        progress: Double,
        report: (@Sendable (Double) async -> Void)?,
    ) async throws {
        guard try await WorkloadOperationStore.setPhase(
            db: db,
            operationID: record.id,
            attemptID: record.attemptID,
            phase: phase,
            progress: progress,
        ) else {
            throw WorkloadOperationInterrupted()
        }
        await report?(progress)
        try gate(phase)
    }

    private static func gate(_ phase: String) throws {
        do {
            try WorkloadEffectGate.pass(phase)
        } catch is WorkloadOperationInterrupted {
            throw WorkloadOperationInterrupted()
        }
    }

    private static func finish(record: WorkloadOperationRecord, db: DatabasePool) async throws {
        guard try await WorkloadOperationStore.complete(
            db: db,
            operationID: record.id,
            attemptID: record.attemptID,
            phase: phaseFinalised,
            recoveryOutcome: outcomeProvisioned,
            resultPayload: record.workloadID,
        ) else {
            throw WorkloadOperationInterrupted()
        }
        await settleTemplateMarker(vmID: record.workloadID, failure: nil, db: db)
    }

    private static func currentPhase(
        operation: WorkloadOperationRecord,
        db: DatabasePool,
    ) async throws -> String {
        guard let row = try await WorkloadOperationStore.fetch(db: db, id: operation.id) else {
            throw BarkVisorError.notFound("operation \(operation.id) not found")
        }
        guard row.attemptID == operation.attemptID else { throw WorkloadOperationInterrupted() }
        return row.phase
    }

    /// Copies a stored record onto the attempt a caller owns, so a superseded worker cannot
    /// finish someone else's record.
    private static func rebound(
        _ stored: WorkloadOperationRecord,
        attemptID: String,
    ) -> WorkloadOperationRecord {
        WorkloadOperationRecord(
            id: stored.id,
            attemptID: attemptID,
            workloadID: stored.workloadID,
            kind: stored.kind,
            requestedGeneration: stored.requestedGeneration,
            phase: stored.phase,
            progress: stored.progress,
            status: stored.status,
            idempotencyKey: stored.idempotencyKey,
            recoveryOutcome: stored.recoveryOutcome,
            resultPayload: stored.resultPayload,
            inputPayload: stored.inputPayload,
            error: stored.error,
            projectPath: stored.projectPath,
            dataRestored: stored.dataRestored,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            finishedAt: stored.finishedAt,
        )
    }

    private static func rank(_ phase: String) -> Int {
        phaseRank[phase] ?? 0
    }
}
