import Foundation
import GRDB

// MARK: - Durable VM delete (BV-06)

/// Drives a `vm.delete` operation through durable phases so an interrupted delete resumes
/// on the next startup instead of stranding the row in `deleting`.
///
/// Phases: `accepted → stopped → resources_released → disks_removed → row_deleted`.
///
/// Every step is idempotent. Re-running a phase after a crash has no adverse second effect:
/// compose teardown is already durable (`appTeardown`), VFIO unbind tolerates an unbound
/// device, disk deletion and directory removal no-op on a missing path, and the row delete
/// is a no-op once the row is gone.
public enum VMDelete {
    public static let phaseAccepted = "accepted"
    public static let phaseStopped = "stopped"
    public static let phaseResourcesReleased = "resources_released"
    public static let phaseDisksRemoved = "disks_removed"
    public static let phaseRowDeleted = "row_deleted"

    public static let outcomeDeleted = "workload_deleted"
    public static let outcomeRefused = "delete_refused"
    public static let outcomeIncomplete = "delete_incomplete"

    /// Ordered so a resumed delete knows which phases still need work.
    static let phaseRank: [String: Int] = [
        phaseAccepted: 0,
        phaseStopped: 1,
        phaseResourcesReleased: 2,
        phaseDisksRemoved: 3,
        phaseRowDeleted: 4,
    ]

    public static func isInterruption(_ error: Error) -> Bool {
        error is WorkloadOperationInterrupted || error is CancellationError
    }

    // MARK: - In-memory path

    /// Runs the delete for a live request, reporting progress onto the background task.
    ///
    /// The record is looked up by the id the caller was handed, so a replay and a resume drive
    /// the same record rather than whatever a regenerated key happens to point at.
    public static func run(
        operationID: String,
        attemptID: String,
        vmManager _: VMManager,
        backgroundTasks: BackgroundTaskManager,
        taskID: String,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        guard let stored = try await WorkloadOperationStore.fetch(db: db, id: operationID) else {
            throw BarkVisorError.notFound("Delete operation \(operationID) not found")
        }
        // Drive the attempt this request owns. If a newer attempt has already taken over, the
        // superseded worker must not touch the record.
        let record = stored.attemptID == attemptID ? stored : WorkloadOperationRecord(
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
        try await drive(record: record, db: db, dataDir: dataDir) { value in
            await backgroundTasks.reportProgress(taskID, progress: value)
        }
    }

    // MARK: - Startup recovery

    /// Resumes a `vm.delete` record left open by a crash. Safe to call when the workload row
    /// is already gone: the record is completed instead.
    public static func recover(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
    ) async throws {
        try await drive(record: record, db: db, dataDir: dataDir, report: nil)
    }

    // MARK: - Phase driver

    static func drive(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        dataDir: URL,
        report: (@Sendable (Double) async -> Void)?,
    ) async throws {
        do {
            try await runPhases(record: record, db: db, dataDir: dataDir, report: report)
        } catch {
            // An interruption must leave the record open and the row `deleting` so the next
            // startup picks it up. A real failure closes the record and resets the row.
            if !isInterruption(error) {
                _ = try? await WorkloadOperationStore.fail(
                    db: db,
                    operationID: record.id,
                    attemptID: record.attemptID,
                    phase: (try? currentPhase(operation: record, db: db)) ?? record.phase,
                    recoveryOutcome: outcomeIncomplete,
                    error: error.localizedDescription,
                )
            }
            throw error
        }
    }

    private static func runPhases(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        dataDir: URL,
        report: (@Sendable (Double) async -> Void)?,
    ) async throws {
        let keepDisk = record.deleteIntent?.keepDisk ?? false
        var phase = try await currentPhase(operation: record, db: db)
        if rank(phase) >= rank(phaseRowDeleted) {
            // The row is already gone; only the completion is outstanding.
            try await finish(record: record, db: db)
            return
        }
        // A delete resumes even when the row vanished mid-cleanup: there is nothing left to
        // release, so finish the record.
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: record.workloadID) }) else {
            try await finish(record: record, db: db)
            return
        }

        if rank(phase) < rank(phaseStopped) {
            try await stopResources(vm: vm, db: db, dataDir: dataDir, operationID: record.id)
            try await checkpoint(record: record, db: db, phase: phaseStopped, progress: 0.3, report: report)
            phase = phaseStopped
        }

        if rank(phase) < rank(phaseResourcesReleased) {
            try await VMLifecycleService.releaseDeleteResources(vm: vm, db: db, dataDir: dataDir)
            try await checkpoint(
                record: record, db: db, phase: phaseResourcesReleased, progress: 0.6, report: report,
            )
            phase = phaseResourcesReleased
        }

        if rank(phase) < rank(phaseDisksRemoved) {
            try await VMLifecycleService.removeDeleteDisks(
                vm: vm, keepDisk: keepDisk, db: db,
            )
            try await checkpoint(
                record: record, db: db, phase: phaseDisksRemoved, progress: 0.85, report: report,
            )
            phase = phaseDisksRemoved
        }

        _ = try await db.write { db in try VM.deleteOne(db, key: record.workloadID) }
        try await checkpoint(
            record: record, db: db, phase: phaseRowDeleted, progress: 1, report: report,
        )
        try await finish(record: record, db: db)
    }

    /// Stops the workload. Applications go through the durable `appTeardown` operation; a
    /// plain VM is already `stopped`/`error` because `canDelete` requires it.
    private static func stopResources(
        vm: VM,
        db: DatabasePool,
        dataDir: URL,
        operationID: String,
    ) async throws {
        guard vm.isApplication else { return }
        try await ApplicationLifecycleService.down(
            vm: vm,
            db: db,
            dataDir: dataDir,
            operationID: operationID,
            holdingSlot: true,
        )
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
            phase: phaseRowDeleted,
            recoveryOutcome: outcomeDeleted,
            resultPayload: record.workloadID,
        ) else {
            throw WorkloadOperationInterrupted()
        }
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

    private static func rank(_ phase: String) -> Int {
        phaseRank[phase] ?? 0
    }
}
