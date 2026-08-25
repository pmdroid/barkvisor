import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class DiskSettingsTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func `default disk path is dataDir disks`() throws {
        let resolved = try dbPool.read { try DiskSettings.resolvedDirectory(from: $0) }
        #expect(resolved.path == Config.dataDir.appendingPathComponent("disks").path)
        #expect(DiskSettings.isDefault(resolved))
    }

    @Test func `custom disk path is read from app_settings`() throws {
        let custom = tmpDir.appendingPathComponent("vm-disks")
        try dbPool.write { db in
            try AppSetting(key: DiskSettings.directoryKey, value: custom.path)
                .save(db, onConflict: .replace)
        }
        let resolved = try dbPool.read { try DiskSettings.resolvedDirectory(from: $0) }
        #expect(resolved.path == custom.standardizedFileURL.path)
        #expect(!DiskSettings.isDefault(resolved))
    }

    @Test func `empty setting falls back to default`() throws {
        try dbPool.write { db in
            try AppSetting(key: DiskSettings.directoryKey, value: "   ")
                .save(db, onConflict: .replace)
        }
        let resolved = try dbPool.read { try DiskSettings.resolvedDirectory(from: $0) }
        #expect(DiskSettings.isDefault(resolved))
    }

    @Test func `relative stored path is rejected on read`() throws {
        try dbPool.write { db in
            try AppSetting(key: DiskSettings.directoryKey, value: "disks")
                .save(db, onConflict: .replace)
        }
        let resolved = try dbPool.read { try DiskSettings.resolvedDirectory(from: $0) }
        #expect(DiskSettings.isDefault(resolved))
    }

    @Test func `empty path resets to default`() throws {
        #expect(try DiskSettings.validateAndPrepare("  ") == nil)
    }

    @Test func `relative path is rejected`() {
        #expect(throws: BarkVisorError.self) {
            try DiskSettings.validateAndPrepare("disks")
        }
        #expect(throws: BarkVisorError.self) {
            try DiskSettings.validateAndPrepare("./disks")
        }
    }

    @Test func `dev path is rejected as disk directory`() {
        #expect(throws: BarkVisorError.self) {
            try DiskSettings.validateAndPrepare("/dev/sdb")
        }
    }

    @Test func `comma in path is rejected`() {
        #expect(throws: BarkVisorError.self) {
            try DiskSettings.validateAndPrepare("/tmp/dis,ks")
        }
    }

    @Test func `missing directory is created when parent is writable`() throws {
        let custom = tmpDir.appendingPathComponent("created-disks")
        let prepared = try DiskSettings.validateAndPrepare(custom.path)
        #expect(prepared?.path == custom.standardizedFileURL.path)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: custom.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func `deleteDisk unlinks a file in the configured disk dir`() async throws {
        let dir = tmpDir.appendingPathComponent("custom-disks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("orphan.qcow2")
        try Data("qcow".utf8).write(to: file)
        try await dbPool.write { db in
            try AppSetting(key: DiskSettings.directoryKey, value: dir.path)
                .save(db, onConflict: .replace)
            try Disk(
                id: "disk-custom",
                name: "orphan",
                path: file.path,
                sizeBytes: 4,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        let cache = DiskInfoCache(dbPool: dbPool)
        _ = try await DiskService.deleteDisk(id: "disk-custom", diskInfoCache: cache, db: dbPool)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func `deleteDisk does not unlink a host device path`() async throws {
        try await dbPool.write { db in
            try Disk(
                id: "disk-dev",
                name: "raw",
                path: "/dev/sdb",
                sizeBytes: 1_000,
                format: "raw",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        let cache = DiskInfoCache(dbPool: dbPool)
        _ = try await DiskService.deleteDisk(id: "disk-dev", diskInfoCache: cache, db: dbPool)
        let gone = try await dbPool.read { db in try Disk.fetchOne(db, key: "disk-dev") }
        #expect(gone == nil)
    }

    @Test func `deleteDisk unlinks a file created in a directory override`() async throws {
        let dir = tmpDir.appendingPathComponent("override-disks")
        let disk = try await DiskService.createDisk(
            name: "override",
            sizeGB: 1,
            format: "qcow2",
            directory: dir.path,
            db: dbPool,
            createBlank: { path, _, _ in
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try Data("qcow".utf8).write(to: path)
            },
        )
        #expect(FileManager.default.fileExists(atPath: disk.path))
        let cache = DiskInfoCache(dbPool: dbPool)
        _ = try await DiskService.deleteDisk(id: disk.id, diskInfoCache: cache, db: dbPool)
        #expect(!FileManager.default.fileExists(atPath: disk.path))
    }
}
