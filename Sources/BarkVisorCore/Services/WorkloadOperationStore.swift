import Foundation
import GRDB

public enum WorkloadOperationStatus {
    public static let running = "running"
    public static let recovering = "recovering"
    public static let completed = "completed"
    public static let failed = "failed"
    public static let cancelled = "cancelled"
}

public enum WorkloadOperationKind {
    public static let appUpdate = "appUpdate"
    public static let appTeardown = "appTeardown"
    public static let vmStart = "vm.start"
}

public enum WorkloadOperationDedup {
    public static let policy = """
    The same idempotency key returns the stored operation for that workload and \
    kind, including after it finishes, and does not start another side effect. \
    The same key for a different workload or kind is rejected. A different key is rejected \
    while that workload and kind already have an open operation. A request with no \
    key replays only an open operation; after the open operation finishes, a missing \
    key starts a new one.
    """
}

public struct WorkloadOperationInterrupted: Error {}

public enum WorkloadEffectGate {
    @TaskLocal public static var hook: (@Sendable (String) throws -> Void)?
    @TaskLocal public static var healthTimeout: TimeInterval?

    public static func pass(_ point: String) throws {
        try hook?(point)
    }

    public static var readinessTimeout: TimeInterval {
        healthTimeout ?? 30
    }
}

public struct WorkloadOperationRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "workload_operations"

    public var id: String
    public var attemptID: String
    public var workloadID: String
    public var kind: String
    public var requestedGeneration: Int
    public var phase: String
    public var progress: Double
    public var status: String
    public var idempotencyKey: String
    public var recoveryOutcome: String?
    public var resultPayload: String?
    public var error: String?
    public var projectPath: String?
    public var dataRestored: Int
    public var createdAt: String
    public var updatedAt: String
    public var finishedAt: String?

    public var isOpen: Bool {
        status == WorkloadOperationStatus.running || status == WorkloadOperationStatus.recovering
    }

    public var isRetryable: Bool {
        status == WorkloadOperationStatus.failed || isOpen
    }

    public func taskEvent() -> BackgroundTaskManager.TaskEvent {
        let mapped: BackgroundTaskManager.TaskStatus = switch status {
        case WorkloadOperationStatus.completed:
            .completed
        case WorkloadOperationStatus.failed:
            .failed
        case WorkloadOperationStatus.cancelled:
            .cancelled
        default:
            .running
        }
        let taskKind = kind == WorkloadOperationKind.appUpdate
            ? BackgroundTaskManager.TaskKind.appUpdate.rawValue
            : kind
        return BackgroundTaskManager.TaskEvent(
            taskID: id,
            kind: taskKind,
            status: mapped,
            progress: progress,
            error: error ?? (status == WorkloadOperationStatus.failed ? recoveryOutcome : nil),
            resultPayload: resultPayload ?? recoveryOutcome,
        )
    }
}

public struct WorkloadOperationAttemptRecord: Codable, Sendable, FetchableRecord, PersistableRecord,
    TableRecord {
    public static let databaseTableName = "workload_operation_attempts"

    public var id: String
    public var operationID: String
    public var status: String
    public var createdAt: String
}

public struct WorkloadOperationAcceptance: Sendable {
    public var record: WorkloadOperationRecord
    public var started: Bool
}

public enum WorkloadOperationStore {
    public static func accept(
        db: DatabasePool,
        idempotencyKey: String?,
        workloadID: String,
        kind: String,
        requestedGeneration: Int,
        projectPath: String? = nil,
    ) async throws -> WorkloadOperationAcceptance {
        try await db.write { db in
            if let idempotencyKey,
               let existing = try WorkloadOperationRecord
               .filter(Column("idempotencyKey") == idempotencyKey)
               .fetchOne(db) {
                if existing.workloadID != workloadID || existing.kind != kind {
                    throw BarkVisorError.conflict(
                        "Idempotency key \(idempotencyKey) is already bound to another workload operation",
                    )
                }
                return WorkloadOperationAcceptance(record: existing, started: false)
            }
            if let open = try openRecord(db: db, workloadID: workloadID, kind: kind) {
                if let idempotencyKey, open.idempotencyKey != idempotencyKey {
                    throw BarkVisorError.conflict(
                        "Workload \(workloadID) already has an open \(kind) operation \(open.id)",
                    )
                }
                return WorkloadOperationAcceptance(record: open, started: false)
            }
            let now = iso8601.string(from: Date())
            let id = UUID().uuidString
            let attemptID = UUID().uuidString
            let record = WorkloadOperationRecord(
                id: id,
                attemptID: attemptID,
                workloadID: workloadID,
                kind: kind,
                requestedGeneration: requestedGeneration,
                phase: "accepted",
                progress: 0,
                status: WorkloadOperationStatus.running,
                idempotencyKey: idempotencyKey ?? id,
                recoveryOutcome: nil,
                resultPayload: nil,
                error: nil,
                projectPath: projectPath,
                dataRestored: 0,
                createdAt: now,
                updatedAt: now,
                finishedAt: nil,
            )
            try record.insert(db)
            try WorkloadOperationAttemptRecord(
                id: attemptID,
                operationID: id,
                status: "active",
                createdAt: now,
            ).insert(db)
            return WorkloadOperationAcceptance(record: record, started: true)
        }
    }

    public static func fetch(db: DatabasePool, id: String) async throws -> WorkloadOperationRecord? {
        try await db.read { db in
            try WorkloadOperationRecord.fetchOne(db, key: id)
        }
    }

    public static func openOperation(
        db: DatabasePool,
        workloadID: String,
        kind: String,
    ) async throws -> WorkloadOperationRecord? {
        try await db.read { db in
            try openRecord(db: db, workloadID: workloadID, kind: kind)
        }
    }

    public static func openOperations(db: DatabasePool) async throws -> [WorkloadOperationRecord] {
        try await db.read { db in
            try WorkloadOperationRecord
                .filter(
                    Column("status") == WorkloadOperationStatus.running
                        || Column("status") == WorkloadOperationStatus.recovering,
                )
                .fetchAll(db)
        }
    }

    public static func failedOperations(db: DatabasePool) async throws -> [WorkloadOperationRecord] {
        try await db.read { db in
            try WorkloadOperationRecord
                .filter(Column("status") == WorkloadOperationStatus.failed)
                .fetchAll(db)
        }
    }

    @discardableResult
    public static func recordProgress(
        db: DatabasePool,
        operationID: String,
        attemptID: String,
        progress: Double,
    ) async throws -> Bool {
        try await db.write { db in
            try mutate(db: db, operationID: operationID, attemptID: attemptID) { record in
                record.progress = progress
                record.updatedAt = iso8601.string(from: Date())
            }
        }
    }

    @discardableResult
    public static func setPhase(
        db: DatabasePool,
        operationID: String,
        attemptID: String,
        phase: String,
        progress: Double? = nil,
    ) async throws -> Bool {
        try await db.write { db in
            try mutate(db: db, operationID: operationID, attemptID: attemptID) { record in
                record.phase = phase
                if let progress {
                    record.progress = progress
                }
                record.updatedAt = iso8601.string(from: Date())
            }
        }
    }

    @discardableResult
    public static func complete(
        db: DatabasePool,
        operationID: String,
        attemptID: String,
        phase: String,
        recoveryOutcome: String? = nil,
        resultPayload: String? = nil,
    ) async throws -> Bool {
        try await db.write { db in
            try finish(
                db: db,
                operationID: operationID,
                attemptID: attemptID,
                status: WorkloadOperationStatus.completed,
                phase: phase,
                recoveryOutcome: recoveryOutcome,
                error: nil,
                resultPayload: resultPayload,
            )
        }
    }

    @discardableResult
    public static func fail(
        db: DatabasePool,
        operationID: String,
        attemptID: String,
        phase: String,
        recoveryOutcome: String,
        error: String,
    ) async throws -> Bool {
        try await db.write { db in
            try finish(
                db: db,
                operationID: operationID,
                attemptID: attemptID,
                status: WorkloadOperationStatus.failed,
                phase: phase,
                recoveryOutcome: recoveryOutcome,
                error: error,
                resultPayload: nil,
            )
        }
    }

    public static func beginReplacement(
        db: DatabasePool,
        operationID: String,
    ) async throws -> WorkloadOperationRecord {
        try await db.write { db in
            guard var record = try WorkloadOperationRecord.fetchOne(db, key: operationID) else {
                throw BarkVisorError.notFound("operation \(operationID) not found")
            }
            let now = iso8601.string(from: Date())
            if var previous = try WorkloadOperationAttemptRecord.fetchOne(db, key: record.attemptID) {
                previous.status = "superseded"
                try previous.update(db)
            } else {
                try WorkloadOperationAttemptRecord(
                    id: record.attemptID,
                    operationID: record.id,
                    status: "superseded",
                    createdAt: record.createdAt,
                ).insert(db)
            }
            let attemptID = UUID().uuidString
            record.attemptID = attemptID
            record.status = WorkloadOperationStatus.recovering
            record.error = nil
            record.finishedAt = nil
            record.updatedAt = now
            try record.update(db)
            try WorkloadOperationAttemptRecord(
                id: attemptID,
                operationID: record.id,
                status: "active",
                createdAt: now,
            ).insert(db)
            return record
        }
    }

    public static func attemptStatus(
        db: DatabasePool,
        attemptID: String,
    ) async throws -> String? {
        try await db.read { db in
            try WorkloadOperationAttemptRecord.fetchOne(db, key: attemptID)?.status
        }
    }

    private static func openRecord(
        db: GRDB.Database,
        workloadID: String,
        kind: String,
    ) throws -> WorkloadOperationRecord? {
        try WorkloadOperationRecord
            .filter(Column("workloadID") == workloadID && Column("kind") == kind)
            .filter(
                Column("status") == WorkloadOperationStatus.running
                    || Column("status") == WorkloadOperationStatus.recovering,
            )
            .fetchOne(db)
    }

    private static func mutate(
        db: GRDB.Database,
        operationID: String,
        attemptID: String,
        body: (inout WorkloadOperationRecord) -> Void,
    ) throws -> Bool {
        guard var record = try WorkloadOperationRecord.fetchOne(db, key: operationID) else {
            return false
        }
        guard record.attemptID == attemptID, record.isOpen else { return false }
        body(&record)
        try record.update(db)
        return true
    }

    private static func finish(
        db: GRDB.Database,
        operationID: String,
        attemptID: String,
        status: String,
        phase: String,
        recoveryOutcome: String?,
        error: String?,
        resultPayload: String?,
    ) throws -> Bool {
        guard var record = try WorkloadOperationRecord.fetchOne(db, key: operationID) else {
            return false
        }
        guard record.attemptID == attemptID, record.isOpen else { return false }
        let now = iso8601.string(from: Date())
        record.status = status
        record.phase = phase
        record.progress = status == WorkloadOperationStatus.completed ? 1 : record.progress
        record.recoveryOutcome = recoveryOutcome
        record.error = error
        record.resultPayload = resultPayload
        record.updatedAt = now
        record.finishedAt = now
        try record.update(db)
        return true
    }
}
