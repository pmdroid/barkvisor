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
    public static let vmDelete = "vm.delete"
    public static let vmProvision = "vm.provision"
}

/// The clone a `vm.provision` operation was accepted for (BV-07). Stored in
/// `workload_operations.inputPayload` so a provision resumed after a crash knows what to
/// clone, where to clone it, and which cloud-init seed to build — with no in-memory context.
public struct WorkloadProvisionIntent: Codable, Sendable, Equatable {
    public var sourceImagePath: String
    public var destinationPath: String
    public var diskID: String
    public var sizeGB: Int?
    public var vmName: String
    public var sshAuthorizedKeys: [String]
    public var userData: String?

    public init(
        sourceImagePath: String,
        destinationPath: String,
        diskID: String,
        sizeGB: Int?,
        vmName: String,
        sshAuthorizedKeys: [String] = [],
        userData: String? = nil,
    ) {
        self.sourceImagePath = sourceImagePath
        self.destinationPath = destinationPath
        self.diskID = diskID
        self.sizeGB = sizeGB
        self.vmName = vmName
        self.sshAuthorizedKeys = sshAuthorizedKeys
        self.userData = userData
    }

    public var hasCloudInit: Bool {
        !sshAuthorizedKeys.isEmpty
            || !(userData?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    public static func encode(_ intent: WorkloadProvisionIntent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intent)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BarkVisorError.internalError("Provision intent could not be encoded")
        }
        return json
    }

    public static func decode(_ payload: String?) -> WorkloadProvisionIntent? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkloadProvisionIntent.self, from: data)
    }
}

/// The request a `vm.delete` operation was accepted for (BV-06). Stored in
/// `workload_operations.inputPayload` so a delete resumed after a crash keeps the
/// caller's intent instead of guessing it.
public struct WorkloadDeleteIntent: Codable, Sendable, Equatable {
    public var keepDisk: Bool
    public var vmName: String

    public init(keepDisk: Bool, vmName: String) {
        self.keepDisk = keepDisk
        self.vmName = vmName
    }

    public static func encode(_ intent: WorkloadDeleteIntent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intent)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BarkVisorError.internalError("Delete intent could not be encoded")
        }
        return json
    }

    public static func decode(_ payload: String?) -> WorkloadDeleteIntent? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkloadDeleteIntent.self, from: data)
    }
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
    /// The request this operation was accepted for. `resultPayload` stays completion output.
    public var inputPayload: String?
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

    /// The delete intent persisted at acceptance, if any.
    public var deleteIntent: WorkloadDeleteIntent? {
        guard kind == WorkloadOperationKind.vmDelete else { return nil }
        return WorkloadDeleteIntent.decode(inputPayload)
    }

    /// The clone intent persisted at acceptance, if any.
    public var provisionIntent: WorkloadProvisionIntent? {
        guard kind == WorkloadOperationKind.vmProvision else { return nil }
        return WorkloadProvisionIntent.decode(inputPayload)
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
        let taskKind = switch kind {
        case WorkloadOperationKind.appUpdate:
            BackgroundTaskManager.TaskKind.appUpdate.rawValue
        case WorkloadOperationKind.vmDelete:
            BackgroundTaskManager.TaskKind.vmDelete.rawValue
        case WorkloadOperationKind.vmProvision:
            BackgroundTaskManager.TaskKind.vmProvision.rawValue
        default:
            kind
        }
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
        inputPayload: String? = nil,
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
                inputPayload: inputPayload,
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

    /// Looks an operation up by the idempotency key a request was accepted with. Used to find
    /// the record a replayed `X-BarkVisor-Operation-Id` owns.
    public static func record(
        db: DatabasePool,
        idempotencyKey: String,
    ) async throws -> WorkloadOperationRecord? {
        try await db.read { db in
            try WorkloadOperationRecord
                .filter(Column("idempotencyKey") == idempotencyKey)
                .fetchOne(db)
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
