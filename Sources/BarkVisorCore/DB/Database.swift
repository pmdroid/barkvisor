import Foundation
import GRDB

/// Protocol for GRDB migrations compatible with our pattern
public protocol DatabaseMigration {
    static var identifier: String { get }
    static func migrate(_ db: GRDB.Database) throws
}

/// GRDB database setup and migration runner
public final class AppDatabase: Sendable {
    public let pool: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.pool = try DatabasePool(path: path, configuration: config)
        // Restrict database file to owner-only access (contains credentials and API key hashes)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public func migrate() throws {
        // Must run before the migrator. GRDB checks FKs when each migration
        // commits, so M005 (ALTER vms) fails if audit_log already has orphans.
        try pool.write { db in
            try Self.repairOrphanAuditForeignKeys(db)
        }
        try AppDatabase.makeMigrator().migrate(pool)
    }

    /// Null dangling `audit_log` references. Safe on a fresh file (no tables yet).
    public static func repairOrphanAuditForeignKeys(_ db: GRDB.Database) throws {
        let tables = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table'",
        )
        guard tables.contains("audit_log") else { return }

        if tables.contains("api_keys") {
            try db.execute(
                sql: """
                UPDATE audit_log
                SET apiKeyId = NULL
                WHERE apiKeyId IS NOT NULL
                  AND apiKeyId NOT IN (SELECT id FROM api_keys)
                """,
            )
        }

        if tables.contains("users") {
            try db.execute(
                sql: """
                UPDATE audit_log
                SET userId = NULL
                WHERE userId IS NOT NULL
                  AND userId NOT IN (SELECT id FROM users)
                """,
            )
        }
    }

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        return migrator
    }

    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        migrator.registerMigration(M002_WorkloadSpec.identifier) { db in
            try M002_WorkloadSpec.migrate(db)
        }
        migrator.registerMigration(M003_ArchitectureAwareTemplates.identifier) { db in
            try M003_ArchitectureAwareTemplates.migrate(db)
        }
        migrator.registerMigration(M004_WorkloadOverrides.identifier) { db in
            try M004_WorkloadOverrides.migrate(db)
        }
        migrator.registerMigration(M005_WorkloadHealth.identifier) { db in
            try M005_WorkloadHealth.migrate(db)
        }
        migrator.registerMigration(M006_ImageSha256.identifier) { db in
            try M006_ImageSha256.migrate(db)
        }
        migrator.registerMigration(M007_RepairOrphanAuditFKs.identifier) { db in
            try M007_RepairOrphanAuditFKs.migrate(db)
        }
        migrator.registerMigration(M008_GuestListeningPorts.identifier) { db in
            try M008_GuestListeningPorts.migrate(db)
        }
        migrator.registerMigration(M009_AuthSessions.identifier) { db in
            try M009_AuthSessions.migrate(db)
        }
        migrator.registerMigration(M010_WorkloadClass.identifier) { db in
            try M010_WorkloadClass.migrate(db)
        }
        migrator.registerMigration(M011_OllamaAPIKeys.identifier) { db in
            try M011_OllamaAPIKeys.migrate(db)
        }
    }
}

/// When `openDatabase()` should replace the live file with a backup.
public enum DatabaseOpenRecovery: Sendable {
    /// Constraint / migration failures are data the next build can repair.
    /// Only treat SQLite corruption as a reason to throw away the live file.
    public static func shouldRestoreFromBackup(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        switch dbError.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }
}

// Vapor storage extensions moved to Sources/BarkVisor/Server/VaporExtensions/DatabaseVaporExtensions.swift
