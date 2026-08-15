import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class LibrarySettingsTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Default / custom resolution

    @Test func `default library path is dataDir images`() throws {
        let resolved = try dbPool.read { try Config.imagesDir(from: $0) }
        #expect(resolved.path == Config.dataDir.appendingPathComponent("images").path)
        #expect(LibrarySettings.isDefault(resolved))
    }

    @Test func `custom library path is read from app_settings`() throws {
        let custom = tmpDir.appendingPathComponent("library")
        try dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: custom.path)
                .save(db, onConflict: .replace)
        }
        let resolved = try dbPool.read { try Config.imagesDir(from: $0) }
        #expect(resolved.path == custom.standardizedFileURL.path)
        #expect(!LibrarySettings.isDefault(resolved))
    }

    @Test func `empty setting falls back to default`() throws {
        try dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: "   ")
                .save(db, onConflict: .replace)
        }
        let resolved = try dbPool.read { try LibrarySettings.resolvedDirectory(from: $0) }
        #expect(LibrarySettings.isDefault(resolved))
    }

    // MARK: - Validation

    @Test func `empty path resets to default`() throws {
        let result = try LibrarySettings.validateAndPrepare("  ")
        #expect(result == nil)
    }

    @Test func `relative path is rejected`() {
        #expect(throws: BarkVisorError.self) {
            try LibrarySettings.validateAndPrepare("images")
        }
        #expect(throws: BarkVisorError.self) {
            try LibrarySettings.validateAndPrepare("./library")
        }
    }

    @Test func `comma in path is rejected`() {
        #expect(throws: BarkVisorError.self) {
            try LibrarySettings.validateAndPrepare("/tmp/lib,rary")
        }
    }

    @Test func `file path is rejected`() throws {
        let file = tmpDir.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: file)
        #expect(throws: BarkVisorError.self) {
            try LibrarySettings.validateAndPrepare(file.path)
        }
    }

    @Test func `unwritable directory is rejected`() throws {
        let ro = tmpDir.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: ro.path,
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: ro.path,
            )
        }
        if !FileManager.default.isWritableFile(atPath: ro.path) {
            #expect(throws: BarkVisorError.self) {
                try LibrarySettings.validateAndPrepare(ro.path)
            }
        }
    }

    @Test func `missing directory is created when parent is writable`() throws {
        let custom = tmpDir.appendingPathComponent("created-library")
        let prepared = try LibrarySettings.validateAndPrepare(custom.path)
        #expect(prepared?.path == custom.standardizedFileURL.path)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: custom.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    // MARK: - Downloads honor the configured dir

    @Test func `finalize tus upload writes into the configured library dir`() async throws {
        let library = tmpDir.appendingPathComponent("tus-library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try await dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
        }

        let now = "2026-01-01T00:00:00Z"
        let image = VMImage(
            id: "img-custom",
            name: "Custom ISO",
            imageType: "iso",
            arch: "arm64",
            path: nil,
            sizeBytes: nil,
            status: "uploading",
            error: nil,
            sourceUrl: nil,
            createdAt: now,
            updatedAt: now,
        )
        let chunk = tmpDir.appendingPathComponent("upload.part")
        try Data("iso-bytes".utf8).write(to: chunk)
        let upload = TusUpload(
            id: "upload-custom",
            imageId: image.id,
            offset: 9,
            length: 9,
            metadata: "",
            chunkPath: chunk.path,
            createdAt: now,
            updatedAt: now,
        )
        try await dbPool.write { db in
            try image.insert(db)
            try upload.insert(db)
        }

        try await ImageService.finalizeTusUpload(upload: upload, db: dbPool)

        let dest = library.appendingPathComponent("img-custom.iso")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let stored = try await dbPool.read { db in try VMImage.fetchOne(db, key: image.id) }
        let digest = try ImageFileChecksum.sha256Hex(ofFile: dest)
        #expect(stored?.status == "ready")
        #expect(stored?.path == dest.path)
        #expect(stored?.sha256 == digest)
    }

    // MARK: - Delete honors Library dir

    @Test func `deleteDisk unlinks a file in the configured library dir`() async throws {
        let library = tmpDir.appendingPathComponent("disk-library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let file = library.appendingPathComponent("orphan.qcow2")
        try Data("qcow".utf8).write(to: file)

        try await dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
            try Disk(
                id: "disk-lib",
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
        _ = try await DiskService.deleteDisk(id: "disk-lib", diskInfoCache: cache, db: dbPool)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let gone = try await dbPool.read { db in try Disk.fetchOne(db, key: "disk-lib") }
        #expect(gone == nil)
    }

    @Test func `deleteDisk skips unlink outside data dir and library dir`() async throws {
        let file = tmpDir.appendingPathComponent("outside.qcow2")
        try Data("qcow".utf8).write(to: file)

        try await dbPool.write { db in
            try Disk(
                id: "disk-out",
                name: "outside",
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
        _ = try await DiskService.deleteDisk(id: "disk-out", diskInfoCache: cache, db: dbPool)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let gone = try await dbPool.read { db in try Disk.fetchOne(db, key: "disk-out") }
        #expect(gone == nil)
    }

    @Test func `managed storage path includes data dir and library dir`() {
        let library = tmpDir.appendingPathComponent("lib")
        let insideLibrary = library.appendingPathComponent("img.iso").path
        let insideData = Config.dataDir.appendingPathComponent("disks/boot.qcow2").path
        #expect(LibrarySettings.isManagedStoragePath(insideLibrary, imagesDir: library))
        #expect(LibrarySettings.isManagedStoragePath(insideData, imagesDir: library))
        #expect(!LibrarySettings.isManagedStoragePath("/etc/passwd", imagesDir: library))
    }
}
