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
        var migrator = DatabaseMigrator()

        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }

        try migrator.migrate(pool)
    }
}

// MARK: - Checkpoint

extension AppDatabase {
    /// Checkpoint WAL and prepare for file replacement (used by restore)
    public func checkpoint() throws {
        try pool.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}

// Vapor storage extensions moved to Sources/BarkVisor/Server/VaporExtensions/DatabaseVaporExtensions.swift
