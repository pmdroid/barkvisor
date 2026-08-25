import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct LogServiceTests {
    // MARK: - LogLevel

    @Test func `log level ordering`() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.error < LogLevel.fatal)
    }

    @Test func `log level raw values`() {
        #expect(LogLevel.debug.rawValue == "debug")
        #expect(LogLevel.info.rawValue == "info")
        #expect(LogLevel.warn.rawValue == "warn")
        #expect(LogLevel.error.rawValue == "error")
        #expect(LogLevel.fatal.rawValue == "fatal")
    }

    @Test func `log level from raw value`() {
        #expect(LogLevel(rawValue: "debug") == .debug)
        #expect(LogLevel(rawValue: "info") == .info)
        #expect(LogLevel(rawValue: "warn") == .warn)
        #expect(LogLevel(rawValue: "error") == .error)
        #expect(LogLevel(rawValue: "fatal") == .fatal)
        #expect(LogLevel(rawValue: "verbose") == nil)
    }

    @Test func `log level not greater than self`() {
        for level in [LogLevel.debug, .info, .warn, .error, .fatal] {
            #expect(!(level < level), "\(level) should not be less than itself")
        }
    }

    // MARK: - LogCategory

    @Test func `log category raw values`() {
        #expect(LogCategory.app.rawValue == "app")
        #expect(LogCategory.server.rawValue == "server")
    }

    @Test func `log category all cases`() {
        #expect(LogCategory.allCases.count == 8)
        #expect(LogCategory.allCases.contains(.app))
        #expect(LogCategory.allCases.contains(.server))
    }

    // MARK: - LogEntry Codable

    @Test func `log entry codable`() throws {
        let entry = LogEntry(
            ts: "2025-01-01T00:00:00Z",
            level: .info,
            cat: .app,
            msg: "Test message",
            vm: "vm-1",
            req: "req-1",
            err: nil,
            detail: ["key": "value"],
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)

        #expect(decoded.ts == entry.ts)
        #expect(decoded.level == entry.level)
        #expect(decoded.cat == entry.cat)
        #expect(decoded.msg == entry.msg)
        #expect(decoded.vm == "vm-1")
        #expect(decoded.req == "req-1")
        #expect(decoded.err == nil)
        #expect(decoded.detail?["key"] == "value")
    }

    @Test func `log entry with error`() throws {
        let entry = LogEntry(
            ts: "2025-01-01T00:00:00Z",
            level: .error,
            cat: .server,
            msg: "Failed",
            vm: nil,
            req: nil,
            err: "something broke",
            detail: nil,
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)

        #expect(decoded.err == "something broke")
        #expect(decoded.vm == nil)
        #expect(decoded.detail == nil)
    }

    // MARK: - SQLITE_FULL / disk-full

    @Test func `isSQLiteFullError matches sqlite and posix copy`() {
        #expect(LogService.isSQLiteFullError(message: "database or disk is full"))
        #expect(LogService.isSQLiteFullError(message: "SQLite error 13: database or disk is full"))
        #expect(LogService.isSQLiteFullError(message: "SQLite error 13: database or disk is full (error-code=13)"))
        #expect(LogService.isSQLiteFullError(message: "SQLITE_FULL"))
        #expect(LogService.isSQLiteFullError(message: "No space left on device"))
        #expect(LogService.isSQLiteFullError(message: "ENOSPC"))
        #expect(!LogService.isSQLiteFullError(message: "database is locked"))
        #expect(!LogService.isSQLiteFullError(message: "SQLITE_BUSY"))
        #expect(!LogService.isSQLiteFullError(message: "permission denied"))
    }

    @Test func `isSQLiteFullError matches GRDB SQLITE_FULL result code`() {
        let full = DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full")
        let busy = DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        #expect(LogService.isSQLiteFullError(full))
        #expect(!LogService.isSQLiteFullError(busy))
    }

    @Test func `prune SQL keeps newest log rows`() throws {
        #expect(LogService.pruneLogsSQL.contains("DELETE FROM logs"))
        #expect(LogService.pruneLogsSQL.contains("ORDER BY ts DESC LIMIT"))
        #expect(LogService.defaultMaxRows == 50_000)
        #expect(LogService.diskFullKeepRows < LogService.defaultMaxRows)

        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue)
        try queue.write { db in
            for i in 1 ... 8 {
                try db.execute(
                    sql: "INSERT INTO logs (ts, level, cat, msg) VALUES (?, 'info', 'app', ?)",
                    arguments: [String(format: "2025-01-01T00:00:%02dZ", i), "m\(i)"],
                )
            }
            try LogService.pruneLogs(in: db, keepRows: 3)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logs")
            #expect(count == 3)
            let msgs = try String.fetchAll(db, sql: "SELECT msg FROM logs ORDER BY ts")
            #expect(msgs == ["m6", "m7", "m8"])
            try LogService.pruneLogs(in: db, keepRows: 50)
            let still = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logs")
            #expect(still == 3)
        }
    }

    @Test func `pruneOldLogs on the actor invokes prune SQL`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try await pool.write { db in
            for i in 1 ... 5 {
                try db.execute(
                    sql: "INSERT INTO logs (ts, level, cat, msg) VALUES (?, 'info', 'app', ?)",
                    arguments: [String(format: "2025-01-01T00:00:%02dZ", i), "row-\(i)"],
                )
            }
        }
        let logs = LogService()
        await logs.setDatabase(pool)
        await logs.pruneOldLogs(keepRows: 2)
        let count = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logs")
        }
        #expect(count == 2)
        let msgs = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT msg FROM logs ORDER BY ts")
        }
        #expect(msgs == ["row-4", "row-5"])
    }

    @Test func `shouldRateLimit suppresses repeating XPC invalidation copy`() {
        let store = LogNoiseWindow()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            LogNoise.shouldRateLimit(
                signature: LogNoise.xpcInvalidationSignature,
                now: t0,
                store: store,
            ) == false,
        )
        #expect(
            LogNoise.shouldRateLimit(
                signature: LogNoise.xpcInvalidationSignature,
                now: t0.addingTimeInterval(15),
                store: store,
            ) == true,
        )
        #expect(
            LogNoise.shouldRateLimit(
                signature: LogNoise.sqliteFullSignature,
                now: t0.addingTimeInterval(15),
                store: store,
            ) == false,
        )
        #expect(
            LogNoise.shouldRateLimit(
                signature: LogNoise.xpcInvalidationSignature,
                now: t0.addingTimeInterval(LogNoise.defaultInterval + 1),
                store: store,
            ) == false,
        )
    }

    @Test func `disk full backup prune keeps newest sqlite`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in [
            "db-2026-01-01T00-00-00Z.sqlite",
            "db-2026-01-02T00-00-00Z.sqlite",
            "db-2026-01-03T00-00-00Z.sqlite",
        ] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let deleted = BackupService.pruneOldestBackupsKeepingNewest(1, in: dir)
        #expect(deleted.sorted() == [
            "db-2026-01-01T00-00-00Z.sqlite",
            "db-2026-01-02T00-00-00Z.sqlite",
        ])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["db-2026-01-03T00-00-00Z.sqlite"])
    }
}
