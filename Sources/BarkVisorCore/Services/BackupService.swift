import Foundation
import GRDB

public struct BackupInfo: Codable, Sendable {
    public let name: String
    public let sizeBytes: Int64
    public let createdAt: String

    public init(
        name: String,
        sizeBytes: Int64,
        createdAt: String,
    ) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

public struct BackupSettings: Codable, Sendable {
    public var enabled: Bool?
    public var retentionDays: Int?
    public var backupDirectory: String?

    public init(
        enabled: Bool?,
        retentionDays: Int?,
        backupDirectory: String?,
    ) {
        self.enabled = enabled
        self.retentionDays = retentionDays
        self.backupDirectory = backupDirectory
    }
}

public enum BackupService {
    private static let lock = NSLock()

    // MARK: - Perform Backup

    /// Creates a timestamped backup via VACUUM INTO. Returns the backup info or nil on failure.
    @discardableResult
    public static func performBackup(pool: DatabasePool, prefix: String = "db") -> BackupInfo? {
        lock.lock()
        defer { lock.unlock() }

        let dir = Config.backupDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = iso8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "\(prefix)-\(timestamp).sqlite"
        let backupPath = dir.appendingPathComponent(filename)

        do {
            try pool.vacuum(into: backupPath.path)
            let size =
                (try? FileManager.default.attributesOfItem(atPath: backupPath.path)[.size] as? Int64) ?? 0
            Log.server.info("Database backup created: \(filename) (\(size) bytes)")
            return BackupInfo(name: filename, sizeBytes: size, createdAt: iso8601.string(from: Date()))
        } catch {
            Log.server.error("Database backup failed: \(error)")
            return nil
        }
    }

    // MARK: - List Backups

    public static func listBackups() -> [BackupInfo] {
        let dir = Config.backupDir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        return
            files
                .filter { $0.hasSuffix(".sqlite") && ($0.hasPrefix("db-") || $0.hasPrefix("pre-restore-")) }
                .compactMap { filename -> BackupInfo? in
                    let path = dir.appendingPathComponent(filename)
                    let size = (try? fm.attributesOfItem(atPath: path.path)[.size] as? Int64) ?? 0
                    let dateStr = extractTimestamp(from: filename)
                    return BackupInfo(name: filename, sizeBytes: size, createdAt: dateStr ?? "")
                }
                .sorted { $0.name > $1.name } // newest first
    }

    // MARK: - Prune Old Backups

    public static func pruneOldBackups() {
        let retentionDays = Config.backupRetentionDays
        let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        let dir = Config.backupDir
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let backups =
            files
                .filter { $0.hasSuffix(".sqlite") && $0.hasPrefix("db-") }
                .sorted()

        // Always keep at least 1 backup
        guard backups.count > 1 else { return }

        for filename in backups.dropLast(1) {
            if let ts = parseTimestamp(from: filename), ts < cutoff {
                try? fm.removeItem(at: dir.appendingPathComponent(filename))
                Log.server.info("Pruned old backup: \(filename)")
            }
        }
    }

    // MARK: - Restore

    /// Restore DB from a backup. Requires no VMs running. Returns new AppDatabase on success.
    public static func restore(from backupName: String, currentPool: DatabasePool) throws
        -> AppDatabase {
        let dir = Config.backupDir
        let backupPath = dir.appendingPathComponent(backupName)
        let fm = FileManager.default

        // Validate backup exists
        guard fm.fileExists(atPath: backupPath.path) else {
            throw BarkVisorError.notFound("Backup not found: \(backupName)")
        }

        // Validate it's a valid SQLite file
        do {
            let testPool = try DatabasePool(path: backupPath.path)
            _ = try testPool.read { db in try Row.fetchOne(db, sql: "SELECT 1") }
        } catch {
            throw BarkVisorError.badRequest("Backup file is not a valid database")
        }

        // Safety backup of current DB
        Log.server.info("Creating pre-restore safety backup...")
        performBackup(pool: currentPool, prefix: "pre-restore")

        // Checkpoint WAL on current DB
        try? currentPool.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        // Replace DB files
        let dbPath = Config.dbPath
        let walPath = URL(fileURLWithPath: dbPath.path + "-wal")
        let shmPath = URL(fileURLWithPath: dbPath.path + "-shm")

        try? fm.removeItem(at: walPath)
        try? fm.removeItem(at: shmPath)
        try? fm.removeItem(at: dbPath)
        try fm.copyItem(at: backupPath, to: dbPath)

        // Open fresh DB and run migrations
        let newDB = try AppDatabase(path: dbPath.path)
        try newDB.migrate()

        Log.server.info("Database restored from \(backupName)")
        return newDB
    }

    /// Finds the most recent backup. Used for startup corruption recovery.
    public static func mostRecentBackup() -> String? {
        listBackups().first?.name
    }

    // MARK: - Settings

    public static func getSettings() -> BackupSettings {
        BackupSettings(
            enabled: Config.backupEnabled,
            retentionDays: Config.backupRetentionDays,
            backupDirectory: Config.backupDir.path,
        )
    }

    public static func updateSettings(_ settings: BackupSettings) {
        if let enabled = settings.enabled {
            UserDefaults.standard.set(enabled, forKey: "backupEnabled")
        }
        if let days = settings.retentionDays, days > 0 {
            UserDefaults.standard.set(days, forKey: "backupRetentionDays")
        }
        if let dir = settings.backupDirectory {
            UserDefaults.standard.set(dir, forKey: "backupDirectory")
        }
    }

    // MARK: - Timestamp Parsing

    /// Extract ISO 8601 timestamp string from backup filename like "db-2026-03-25T20-30-00Z.sqlite"
    private static func extractTimestamp(from filename: String) -> String? {
        // Strip prefix and .sqlite suffix
        var ts = filename
        for prefix in ["pre-restore-", "db-"] where ts.hasPrefix(prefix) {
            ts = String(ts.dropFirst(prefix.count))
            break
        }
        if ts.hasSuffix(".sqlite") { ts = String(ts.dropLast(7)) }
        return ts.replacingOccurrences(of: "-", with: ":")
            .replacingOccurrences(of: "T:", with: "T") // keep the T separator clean
    }

    /// Parse the timestamp from a backup filename into a Date
    private static func parseTimestamp(from filename: String) -> Date? {
        guard let ts = extractTimestamp(from: filename) else { return nil }
        return iso8601.date(from: ts)
    }
}
