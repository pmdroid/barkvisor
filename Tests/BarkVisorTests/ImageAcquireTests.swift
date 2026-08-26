import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct ImageAcquireTests {
    private func pool() throws -> (DatabasePool, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(pool)
        return (pool, tmp)
    }

    @Test func `readyImage matches sha256 case-insensitively`() throws {
        let (dbPool, tmp) = try pool()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = "2026-01-01T00:00:00Z"
        try dbPool.write { db in
            try VMImage(
                id: "img-1",
                name: "ubuntu",
                imageType: "cloud-image",
                arch: "arm64",
                path: "/tmp/ubuntu.img",
                sizeBytes: 1,
                status: "ready",
                error: nil,
                sourceUrl: "https://example.test/ubuntu.img",
                sha256: "AbC123",
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
        let found = try dbPool.read { db in
            try ImageService.readyImage(sha256: "abc123", db: db)
        }
        #expect(found?.id == "img-1")
    }

    @Test func `depot catalog lists by sha256`() throws {
        let (dbPool, tmp) = try pool()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("disk.img")
        try Data("x".utf8).write(to: file)
        let now = "2026-01-01T00:00:00Z"
        try dbPool.write { db in
            try VMImage(
                id: "img-1",
                name: "upload",
                imageType: "iso",
                arch: "arm64",
                path: file.path,
                sizeBytes: 1,
                status: "ready",
                error: nil,
                sourceUrl: nil,
                sha256: "deadbeef",
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
        let listed = try dbPool.read { db in
            try LibraryDepotCatalog.list(db: db, sourceUrl: nil, sha256: "deadbeef")
        }
        #expect(listed.map(\.id) == ["img-1"])
    }
}
