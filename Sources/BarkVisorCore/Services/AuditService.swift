import Foundation
import GRDB

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
