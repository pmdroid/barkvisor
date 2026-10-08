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

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createBackup(at path: URL) throws {
        let database = try AppDatabase(path: path.path)
        try database.migrate()
        try database.pool.write { db in
            try AppSetting(key: "proof", value: "retained").insert(db)
        }
        try database.pool.close()
    }

    private func marker(at path: URL) throws -> String? {
        let database = try DatabaseQueue(path: path.path)
        return try database.read { db in try AppSetting.fetchOne(db, key: "proof")?.value }
    }
}
