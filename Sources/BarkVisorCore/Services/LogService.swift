import Foundation
import GRDB
#if canImport(os)
    import os
#endif

// MARK: - Log Types

public enum LogLevel: String, Codable, Comparable, Sendable {
    case debug, info, warn, error, fatal

    private var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        case .fatal: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.order < rhs.order
    }
}

public enum LogCategory: String, Codable, CaseIterable, Sendable {
    case app, server, vm, auth, images, metrics, audit, sync
}

public struct LogEntry: Codable, Sendable {
    public let ts: String
    public let level: LogLevel
    public let cat: LogCategory
    public let msg: String
    public var vm: String?
    public var req: String?
    public var err: String?
    public var detail: [String: String]?

    public init(
        ts: String,
        level: LogLevel,
        cat: LogCategory,
        msg: String,
        vm: String?,
        req: String?,
        err: String?,
        detail: [String: String]?,
    ) {
        self.ts = ts
        self.level = level
        self.cat = cat
        self.msg = msg
        self.vm = vm
        self.req = req
        self.err = err
        self.detail = detail
    }
}

// MARK: - LogService

public actor LogService {
    public static let shared = LogService()

    public static let defaultMaxRows = 50_000
    public static let diskFullKeepRows = 5_000
    public nonisolated static let pruneLogsSQL = """
    DELETE FROM logs WHERE id NOT IN (
        SELECT id FROM logs ORDER BY ts DESC LIMIT ?
    )
    """

    private var dbPool: DatabasePool?
    private let minLevel: LogLevel
    private let encoder = JSONEncoder()
    private var tailContinuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    private var skipDatabaseInserts = false
    private var reclaimingDisk = false

    public init() {
        self.minLevel = .info
    }

    private nonisolated static func platformLog(_ message: String, level: LogLevel = .error) {
        #if canImport(os)
            let type: OSLogType = {
                switch level {
                case .debug: return .debug
                case .info: return .info
                case .warn: return .default
                case .error: return .error
                case .fatal: return .fault
                }
            }()
            os_log("%{public}@", log: OSLog(subsystem: "dev.barkvisor.app", category: "app"), type: type, message)
        #else
            FileHandle.standardError.write(Data((message + "\n").utf8))
        #endif
    }

    /// Must be called once at startup to provide the database pool.
    public func setDatabase(_ pool: DatabasePool) {
        self.dbPool = pool
    }

    // MARK: - Public API

    public func log(
        _ level: LogLevel,
        _ msg: String,
        category: LogCategory = .app,
        vm vmId: String? = nil,
        req: String? = nil,
        error: String? = nil,
        detail: [String: String]? = nil,
    ) {
        guard level >= minLevel else { return }

        let entry = LogEntry(
            ts: iso8601.string(from: Date()),
            level: level,
            cat: category,
            msg: msg,
            vm: vmId,
            req: req,
            err: error,
            detail: detail,
        )

        // Write to DB — skip inserts while SQLITE_FULL reclaim is in flight.
        if let dbPool, !skipDatabaseInserts {
            let detailJSON: String? = detail.flatMap {
                try? String(data: encoder.encode($0), encoding: .utf8)
            }
            Task {
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: """
                                INSERT INTO logs (ts, level, cat, msg, vm, req, err, detail)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                entry.ts, entry.level.rawValue, entry.cat.rawValue,
                                entry.msg, entry.vm, entry.req, entry.err, detailJSON,
                            ],
                        )
                    }
                } catch {
                    await self.handleWriteFailure(error)
                }
            }
        }

        Self.platformLog("[\(category.rawValue)] \(msg)", level: level)

        // Notify tail listeners
        for (_, cont) in tailContinuations {
            cont.yield(entry)
        }
    }

    /// Convenience methods
    public func debug(
        _ msg: String, category: LogCategory = .app, vm: String? = nil, detail: [String: String]? = nil,
    ) {
        log(.debug, msg, category: category, vm: vm, detail: detail)
    }

    public func info(
        _ msg: String, category: LogCategory = .app, vm: String? = nil, detail: [String: String]? = nil,
    ) {
        log(.info, msg, category: category, vm: vm, detail: detail)
    }

    public func warn(
        _ msg: String, category: LogCategory = .app, vm: String? = nil, error: String? = nil,
    ) {
        log(.warn, msg, category: category, vm: vm, error: error)
    }

    public func error(
        _ msg: String, category: LogCategory = .app, vm: String? = nil, error: String? = nil,
        detail: [String: String]? = nil,
    ) {
        log(.error, msg, category: category, vm: vm, error: error, detail: detail)
    }

    // MARK: - Log Reading

    public func readLogs(
        category: LogCategory? = nil,
        level: LogLevel? = nil,
        since: Date? = nil,
        limit: Int = 500,
        search: String? = nil,
    ) -> [LogEntry] {
        guard let dbPool else { return [] }

        var conditions: [String] = []
        var args: [DatabaseValueConvertible?] = []

        if let cat = category {
            conditions.append("cat = ?")
            args.append(cat.rawValue)
        }
        if let lvl = level {
            let validLevels = LogLevel.allValues.filter { $0 >= lvl }.map(\.rawValue)
            let placeholders = validLevels.map { _ in "?" }.joined(separator: ", ")
            conditions.append("level IN (\(placeholders))")
            args.append(contentsOf: validLevels)
        }
        if let since {
            conditions.append("ts >= ?")
            args.append(iso8601.string(from: since))
        }
        if let q = search, !q.isEmpty {
            conditions.append("(msg LIKE ? ESCAPE '\\' OR err LIKE ? ESCAPE '\\')")
            // Escape LIKE wildcards to prevent pattern-based data extraction
            let escaped =
                q
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            args.append(pattern)
            args.append(pattern)
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = "SELECT * FROM logs \(whereClause) ORDER BY ts DESC LIMIT ?"
        args.append(min(limit, 5_000))

        let decoder = JSONDecoder()

        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return rows.compactMap { row -> LogEntry? in
                    guard let levelStr: String = row["level"],
                          let level = LogLevel(rawValue: levelStr),
                          let catStr: String = row["cat"],
                          let cat = LogCategory(rawValue: catStr)
                    else { return nil }

                    let detailDict: [String: String]? = (row["detail"] as String?).flatMap {
                        try? decoder.decode([String: String].self, from: Data($0.utf8))
                    }

                    return LogEntry(
                        ts: row["ts"],
                        level: level,
                        cat: cat,
                        msg: row["msg"],
                        vm: row["vm"],
                        req: row["req"],
                        err: row["err"],
                        detail: detailDict,
                    )
                }
            }
        } catch {
            Self.platformLog("LogService DB read failed: \(error.localizedDescription)")
            return []
        }
    }

    public func tailLogs() -> AsyncStream<LogEntry> {
        let id = UUID()
        return AsyncStream { continuation in
            tailContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await LogService.shared.removeTail(id: id) }
            }
        }
    }

    private func removeTail(id: UUID) {
        tailContinuations.removeValue(forKey: id)
    }

    // MARK: - Pruning

    public func pruneOldLogs(keepRows: Int = LogService.defaultMaxRows) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try Self.pruneLogs(in: db, keepRows: keepRows)
            }
        } catch {
            if !LogNoise.shouldRateLimit(signature: "logservice.prune") {
                Self.platformLog("LogService prune failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleWriteFailure(_ error: Error) async {
        if Self.isSQLiteFullError(error) {
            await reclaimAfterDiskFull()
            return
        }
        if !LogNoise.shouldRateLimit(signature: "logservice.db-write") {
            Self.platformLog("LogService DB write failed: \(error.localizedDescription)")
        }
    }

    private func reclaimAfterDiskFull() async {
        guard !reclaimingDisk else { return }
        reclaimingDisk = true
        skipDatabaseInserts = true
        defer {
            reclaimingDisk = false
            skipDatabaseInserts = false
        }
        await pruneOldLogs(keepRows: Self.diskFullKeepRows)
        _ = BackupService.pruneOldestBackupsKeepingNewest(1)
        emitDiskFullWarning()
    }

    private func emitDiskFullWarning() {
        if LogNoise.shouldRateLimit(signature: LogNoise.sqliteFullSignature) {
            return
        }
        let msg =
            "Log database or disk is full; pruned logs and skipped inserts. Free space under \(Config.dataDir.path)."
        Self.platformLog(msg, level: .warn)
        let entry = LogEntry(
            ts: iso8601.string(from: Date()),
            level: .warn,
            cat: .server,
            msg: msg,
            vm: nil,
            req: nil,
            err: "SQLITE_FULL",
            detail: nil,
        )
        for (_, cont) in tailContinuations {
            cont.yield(entry)
        }
    }

    // MARK: - Diagnostic Bundle

    public func collectDiagnosticFiles() -> [(name: String, url: URL)] {
        // DB-backed logs are included via the main database file
        return []
    }
}

// MARK: - LogLevel helpers

extension LogLevel {
    static let allValues: [LogLevel] = [.debug, .info, .warn, .error, .fatal]
}

extension LogService {
    /// SQLITE_FULL (13) and host ENOSPC copy from GRDB / sqlite / the OS.
    public nonisolated static func isSQLiteFullError(message: String) -> Bool {
        let t = message.lowercased()
        if t.contains("database or disk is full") { return true }
        if t.contains("sqlite_full") { return true }
        if t.contains("no space left") { return true }
        if t.contains("enospc") { return true }
        if t.contains("error-code=13") { return true }
        if t.contains("error code: 13") { return true }
        if t.contains("sqlite error 13") { return true }
        return false
    }

    public nonisolated static func isSQLiteFullError(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError, dbError.resultCode == .SQLITE_FULL {
            return true
        }
        return isSQLiteFullError(message: error.localizedDescription)
    }

    /// Keep the newest `keepRows` log rows. No-op when already at or under the cap.
    public nonisolated static func pruneLogs(in db: GRDB.Database, keepRows: Int) throws {
        guard keepRows > 0 else { return }
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logs") ?? 0
        guard count > keepRows else { return }
        try db.execute(sql: pruneLogsSQL, arguments: [keepRows])
    }
}
