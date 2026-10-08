import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct BackupIntegrityTests {
    @Test func `reclaim preserves a valid backup instead of the newer empty candidate`() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = dir.appendingPathComponent("db-2026-10-07T00-00-00Z.sqlite")
        try createBackup(at: valid)
        let invalid = dir.appendingPathComponent("db-2026-10-08T00-00-00Z.sqlite")
        try Data().write(to: invalid)
        _ = BackupService.pruneOldestBackupsKeepingNewest(1, in: dir)
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(try marker(at: valid) == "retained")
        #expect(!FileManager.default.fileExists(atPath: invalid.path))
    }

    @Test func `reclaim preserves valid content instead of a newer corrupt candidate`() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = dir.appendingPathComponent("db-2026-10-07T00-00-00Z.sqlite")
        try createBackup(at: valid)
        let corrupt = dir.appendingPathComponent("db-2026-10-08T00-00-00Z.sqlite")
        try Data("not a SQLite database".utf8).write(to: corrupt)
        _ = BackupService.pruneOldestBackupsKeepingNewest(1, in: dir)
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(try marker(at: valid) == "retained")
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test func `failed publication removes partial files and retains recovery selection`() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = dir.appendingPathComponent("db-2026-10-07T00-00-00Z.sqlite")
        try createBackup(at: valid)
        let database = try AppDatabase(path: dir.appendingPathComponent("live.sqlite").path)
        try database.migrate()
        let result = BackupService.performBackup(
            pool: database.pool,
            directory: dir,
            now: Date(timeIntervalSince1970: 1_791_446_400),
            vacuum: { path in
                #expect(!path.hasSuffix(".sqlite"))
                try Data().write(to: URL(fileURLWithPath: path))
                throw DatabaseError(resultCode: .SQLITE_FULL, message: "injected full")
            },
        )
        #expect(result == nil)
        #expect(try marker(at: valid) == "retained")
        #expect(BackupService.mostRecentBackup(directory: dir) == valid.lastPathComponent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
            $0.hasSuffix(".backup-pending")
        } == false)
    }

    @Test func `ENOSPC and interrupted partial writes retain the valid backup`() throws {
        for error in [NSError(domain: NSPOSIXErrorDomain, code: 28), NSError(domain: "partial", code: 1)] {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let valid = dir.appendingPathComponent("db-2026-10-07T00-00-00Z.sqlite")
            try createBackup(at: valid)
            let database = try AppDatabase(path: dir.appendingPathComponent("live.sqlite").path)
            try database.migrate()
            let result = BackupService.performBackup(
                pool: database.pool, directory: dir, now: Date(),
                vacuum: { path in
                    try Data("partial SQLite header".utf8).write(to: URL(fileURLWithPath: path))
                    throw error
                },
            )
            #expect(result == nil)
            #expect(try marker(at: valid) == "retained")
            #expect(BackupService.mostRecentBackup(directory: dir) == valid.lastPathComponent)
        }
    }

    @Test func `cancelled backup does not publish or discard its previous restore point`() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = dir.appendingPathComponent("db-2026-10-07T00-00-00Z.sqlite")
        try createBackup(at: valid)
        let database = try AppDatabase(path: dir.appendingPathComponent("live.sqlite").path)
        try database.migrate()
        let task = Task { () -> BackupInfo? in
            withUnsafeCurrentTask { $0?.cancel() }
            return BackupService.performBackup(pool: database.pool, directory: dir, now: Date())
        }
        #expect(await task.value == nil)
        #expect(try marker(at: valid) == "retained")
        #expect(BackupService.mostRecentBackup(directory: dir) == valid.lastPathComponent)
    }

    @Test func `publication validates content before making a final backup visible`() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try AppDatabase(path: dir.appendingPathComponent("live.sqlite").path)
        try database.migrate()
        try database.pool.write { db in try AppSetting(key: "proof", value: "retained").insert(db) }
        let result = try #require(BackupService.performBackup(
            pool: database.pool, directory: dir, now: Date(timeIntervalSince1970: 1_791_446_400),
        ))
        #expect(result.sizeBytes > 0)
        #expect(try marker(at: dir.appendingPathComponent(result.name)) == "retained")
        #expect(BackupService.mostRecentBackup(directory: dir) == result.name)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
            $0.hasSuffix(".backup-pending")
        } == false)
    }

    @Test func `restore selection skips empty corrupt and unrelated SQLite candidates`() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = dir.appendingPathComponent("db-2026-10-07T00-00-00Z.sqlite")
        try createBackup(at: valid)
        try Data().write(to: dir.appendingPathComponent("db-2026-10-08T00-00-00Z.sqlite"))
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent("db-2026-10-09T00-00-00Z.sqlite"))
        let unrelated = try DatabaseQueue(path: dir.appendingPathComponent("db-2026-10-10T00-00-00Z.sqlite").path)
        try unrelated.write { db in try db.execute(sql: "CREATE TABLE unrelated (id INTEGER)") }
        #expect(BackupService.mostRecentBackup(directory: dir) == valid.lastPathComponent)
        #expect(BackupService.listBackups(directory: dir).map(\.name) == [valid.lastPathComponent])
    }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createBackup(at path: URL) throws {
        let source = path.appendingPathExtension("source")
        let database = try AppDatabase(path: source.path)
        try database.migrate()
        try database.pool.write { db in
            try AppSetting(key: "proof", value: "retained").insert(db)
        }
        try database.pool.vacuum(into: path.path)
        try database.pool.close()
        try FileManager.default.removeItem(at: source)
    }

    private func marker(at path: URL) throws -> String? {
        let database = try DatabaseQueue(path: path.path)
        return try database.read { db in try AppSetting.fetchOne(db, key: "proof")?.value }
    }
}
