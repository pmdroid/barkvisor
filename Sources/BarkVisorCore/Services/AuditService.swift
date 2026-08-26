import Foundation
import GRDB

public enum VMLifecycleAction {
    public static let started = "vm.started"
    public static let stopped = "vm.stopped"
    public static let crashed = "vm.crashed"
    public static let restarted = "vm.restarted"
    public static let legacy = ["vm.start", "vm.stop", "vm.restart"]
    public static let feed = [started, stopped, crashed, restarted] + legacy
}

public enum AuditService {
    /// Log an audit entry with explicit user context.
    public static func log(
        action: String,
        resourceType: String? = nil,
        resourceId: String? = nil,
        resourceName: String? = nil,
        detail: String? = nil,
        userId: String? = nil,
        username: String? = nil,
        authMethod: String? = nil,
        apiKeyId: String? = nil,
        db: DatabasePool,
    ) {
        let entry = AuditEntry(
            id: nil,
            timestamp: iso8601.string(from: Date()),
            userId: userId,
            username: username,
            action: action,
            resourceType: resourceType,
            resourceId: resourceId,
            resourceName: resourceName,
            detail: detail,
            authMethod: authMethod,
            apiKeyId: apiKeyId,
        )

        Task {
            do {
                try await db.write { db in
                    try entry.insert(db)
                }
            } catch {
                Log.audit.error("Failed to write audit log entry (\(action)): \(error)")
            }
        }
    }

    /// Log a system event (no request context, e.g. app startup/shutdown)
    public static func logSystem(
        action: String,
        detail: String? = nil,
        db: DatabasePool,
    ) async {
        let entry = AuditEntry(
            id: nil,
            timestamp: iso8601.string(from: Date()),
            userId: nil,
            username: nil,
            action: action,
            resourceType: "system",
            resourceId: nil,
            resourceName: nil,
            detail: detail,
            authMethod: nil,
            apiKeyId: nil,
        )
        do {
            try await db.write { db in
                try entry.insert(db)
            }
        } catch {
            Log.audit.error("Failed to write system audit log entry (\(action)): \(error)")
        }
    }

    public static func logVMEvent(
        action: String,
        vmID: String,
        detail: String? = nil,
        db: DatabasePool,
    ) async {
        let entry = AuditEntry(
            id: nil,
            timestamp: iso8601.string(from: Date()),
            userId: nil,
            username: nil,
            action: action,
            resourceType: "vm",
            resourceId: vmID,
            resourceName: nil,
            detail: detail,
            authMethod: nil,
            apiKeyId: nil,
        )
        do {
            try await db.write { db in try entry.insert(db) }
        } catch {
            Log.audit.error("Failed to write VM lifecycle event (\(action)): \(error)")
        }
    }

    public static func vmEvents(
        vmID: String,
        limit: Int = 100,
        db: DatabasePool,
    ) async throws -> [AuditEntry] {
        try await db.read { db in
            try AuditEntry
                .filter(AuditEntry.Columns.resourceType == "vm")
                .filter(AuditEntry.Columns.resourceId == vmID)
                .filter(VMLifecycleAction.feed.contains(AuditEntry.Columns.action))
                .order(AuditEntry.Columns.id.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Remove entries older than 90 days. Retries up to 3 times on failure.
    public static func pruneOldEntries(db: DatabasePool) async {
        let cutoff = iso8601.string(
            from: Date().addingTimeInterval(-90 * 86_400),
        )
        for attempt in 1 ... 3 {
            do {
                let deleted = try await db.write { db -> Int in
                    try db.execute(
                        sql: "DELETE FROM audit_log WHERE timestamp < ?",
                        arguments: [cutoff],
                    )
                    return db.changesCount
                }
                if deleted > 0 {
                    Log.audit.info("Pruned \(deleted) audit log entries older than 90 days")
                }
                return
            } catch {
                Log.audit.error("Failed to prune audit entries (attempt \(attempt)/3): \(error)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
            }
        }
    }
}
