import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class StubBlockFileManager: FileManager, @unchecked Sendable {
    var blockPaths: Set<String> = []
    var sizes: [String: Int64] = [:]

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if blockPaths.contains(path) {
            return [
                .type: FileAttributeType.typeBlockSpecial,
                .size: sizes[path] ?? Int64(0),
            ]
        }
        return try super.attributesOfItem(atPath: path)
    }
}

final class DiskServiceCreateTests {
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

    private func expectCreateFails(
        name: String = "bad",
        sizeGB: Int? = 1,
        format: String? = "qcow2",
        directory: String? = nil,
        blockDevice: String? = nil,
        fileManager: FileManager = .default,
        allowBlockDevices: Bool? = nil,
    ) async throws {
        do {
            _ = try await DiskService.createDisk(
                name: name,
                sizeGB: sizeGB,
                format: format,
                directory: directory,
                blockDevice: blockDevice,
                db: dbPool,
                fileManager: fileManager,
                allowBlockDevices: allowBlockDevices,
                createBlank: { _, _, _ in
                    Issue.record("qemu-img must not run")
                },
            )
            Issue.record("expected createDisk to throw")
        } catch is BarkVisorError {
        }
        let count = try await dbPool.read { db in try Disk.fetchCount(db) }
        #expect(count == 0)
    }

    @Test func `createDisk joins the default disk directory`() async throws {
        var written: URL?
        let disk = try await DiskService.createDisk(
            name: "boot",
            sizeGB: 2,
            format: "qcow2",
            db: dbPool,
            createBlank: { path, _, _ in written = path },
        )
        #expect(disk.path.hasPrefix(DiskSettings.defaultDirectory.path + "/"))
        #expect(disk.path.hasSuffix(".qcow2"))
        #expect(written?.path == disk.path)
        #expect(disk.format == "qcow2")
    }

    @Test func `createDisk uses a custom directory override`() async throws {
        let dir = tmpDir.appendingPathComponent("override")
        var written: URL?
        let disk = try await DiskService.createDisk(
            name: "data",
            sizeGB: 4,
            format: "raw",
            directory: dir.path,
            db: dbPool,
            createBlank: { path, _, _ in
                written = path
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try Data().write(to: path)
            },
        )
        #expect(disk.path.hasPrefix(dir.standardizedFileURL.path + "/"))
        #expect(disk.path.hasSuffix(".img"))
        #expect(written?.path == disk.path)
        #expect(FileManager.default.fileExists(atPath: disk.path))
    }

    @Test func `createDisk uses persisted default directory`() async throws {
        let dir = tmpDir.appendingPathComponent("persisted")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await dbPool.write { db in
            try AppSetting(key: DiskSettings.directoryKey, value: dir.path)
                .save(db, onConflict: .replace)
        }
        let disk = try await DiskService.createDisk(
            name: "persist",
            sizeGB: 1,
            format: "qcow2",
            db: dbPool,
            createBlank: { path, _, _ in
                try Data().write(to: path)
            },
        )
        #expect(disk.path.hasPrefix(dir.standardizedFileURL.path + "/"))
    }

    @Test func `createDisk rejects a relative directory with no record`() async throws {
        try await expectCreateFails(directory: "relative/disks")
    }

    @Test func `createDisk rejects block devices when disallowed`() async throws {
        try await expectCreateFails(
            format: "raw",
            blockDevice: "/dev/sdb",
            allowBlockDevices: false,
        )
    }

    @Test func `createDisk rejects block devices on darwin by default`() async throws {
        #if os(macOS)
            try await expectCreateFails(format: "raw", blockDevice: "/dev/sdb")
        #endif
    }

    @Test func `createDisk attaches a fake block path as raw without qemu-img`() async throws {
        let fm = StubBlockFileManager()
        fm.blockPaths = ["/dev/sdb"]
        fm.sizes = ["/dev/sdb": 10_737_418_240]
        var qemuCalled = false
        let disk = try await DiskService.createDisk(
            name: "passthrough",
            sizeGB: 1,
            format: "qcow2",
            blockDevice: "/dev/sdb",
            db: dbPool,
            fileManager: fm,
            allowBlockDevices: true,
            createBlank: { _, _, _ in qemuCalled = true },
        )
        #expect(!qemuCalled)
        #expect(disk.path == "/dev/sdb")
        #expect(disk.format == "raw")
        #expect(disk.sizeBytes == 10_737_418_240)
    }

    @Test func `createDisk rejects a non-block path with no record`() async throws {
        try await expectCreateFails(
            format: "raw",
            blockDevice: "/dev/null",
            allowBlockDevices: true,
        )
    }

    @Test func `createDisk rejects a non-dev path with no record`() async throws {
        let file = tmpDir.appendingPathComponent("not-a-device")
        try Data("x".utf8).write(to: file)
        try await expectCreateFails(
            format: "raw",
            blockDevice: file.path,
            allowBlockDevices: true,
        )
    }
}
