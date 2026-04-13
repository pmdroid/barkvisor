import CryptoKit
import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class ImageChecksumTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let downloader: ImageDownloader

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(pool)
        dbPool = pool

        downloader = ImageDownloader(dbPool: { [pool] in pool })
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Schema

    @Test func `repository images table has checksum columns`() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "repository_images").map(\.name)
            #expect(columns.contains("sha256"), "repository_images should have sha256 column")
            #expect(columns.contains("sha512"), "repository_images should have sha512 column")
        }
    }

    // MARK: - RepoCatalogImage parsing

    @Test func `repo catalog image decodes checksums`() throws {
        let json = """
        {
            "slug": "test-img",
            "name": "Test Image",
            "imageType": "iso",
            "arch": "arm64",
            "downloadUrl": "https://example.com/test.iso",
            "sha256": "abcdef1234567890"
        }
        """
        let image = try JSONDecoder().decode(RepoCatalogImage.self, from: Data(json.utf8))
        #expect(image.sha256 == "abcdef1234567890")
        #expect(image.sha512 == nil)
    }

    @Test func `repo catalog image decodes without checksums`() throws {
        let json = """
        {
            "slug": "test-img",
            "name": "Test Image",
            "imageType": "iso",
            "arch": "arm64",
            "downloadUrl": "https://example.com/test.iso"
        }
        """
        let image = try JSONDecoder().decode(RepoCatalogImage.self, from: Data(json.utf8))
        #expect(image.sha256 == nil)
        #expect(image.sha512 == nil)
    }

    // MARK: - RepositoryImage DB round-trip

    @Test func `repository image checksum round trip`() async throws {
        // Insert a repository first
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO image_repositories (id, name, url, repoType, createdAt, updatedAt)
                    VALUES ('repo-1', 'Test', 'https://example.com/repo.json', 'images', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """,
            )
        }

        let img = RepositoryImage(
            id: "ri-1", repositoryId: "repo-1", slug: "test",
            name: "Test", description: nil, imageType: "iso", arch: "arm64",
            version: "1.0", downloadUrl: "https://example.com/test.iso",
            sizeBytes: 1_000, sha256: "abc123", sha512: nil,
        )

        try await dbPool.write { db in try img.insert(db) }

        let fetched = try await dbPool.read { db in
            try RepositoryImage.fetchOne(db, key: "ri-1")
        }
        #expect(fetched?.sha256 == "abc123")
        #expect(fetched?.sha512 == nil)
    }

    // MARK: - Checksum verification (via downloader)

    @Test func `download with correct SHA 256 succeeds`() async throws {
        let content = Data("hello world".utf8)
        let hash = SHA256.hash(data: content).compactMap { String(format: "%02x", $0) }.joined()

        // Serve a local file via file:// URL
        let sourceFile = tmpDir.appendingPathComponent("source.iso")
        try content.write(to: sourceFile)

        let now = iso8601.string(from: Date())
        let imageID = "img-sha256-ok"
        try await dbPool.write { db in
            let image = VMImage(
                id: imageID, name: "Test", imageType: "iso", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: sourceFile.absoluteString, createdAt: now, updatedAt: now,
            )
            try image.insert(db)
        }

        let dest = tmpDir.appendingPathComponent("dest.iso")
        await downloader.start(
            imageID: imageID, url: sourceFile, destination: dest, expectedChecksum: .sha256(hash),
        )

        // Wait for completion
        let stream = await downloader.progressStream(imageID: imageID)
        for await event in stream {
            if event.status == "ready" || event.status == "error" {
                break
            }
        }

        let image = try await dbPool.read { db in try VMImage.fetchOne(db, key: imageID) }
        #expect(image?.status == "ready", "Download with correct SHA256 should succeed")
    }

    @Test func `download with wrong SHA 256 fails`() async throws {
        let content = Data("hello world".utf8)

        let sourceFile = tmpDir.appendingPathComponent("source2.iso")
        try content.write(to: sourceFile)

        let now = iso8601.string(from: Date())
        let imageID = "img-sha256-bad"
        try await dbPool.write { db in
            let image = VMImage(
                id: imageID, name: "Test", imageType: "iso", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: sourceFile.absoluteString, createdAt: now, updatedAt: now,
            )
            try image.insert(db)
        }

        let dest = tmpDir.appendingPathComponent("dest2.iso")
        await downloader.start(
            imageID: imageID, url: sourceFile, destination: dest,
            expectedChecksum: .sha256("0000000000000000000000000000000000000000000000000000000000000000"),
        )

        let stream = await downloader.progressStream(imageID: imageID)
        for await event in stream {
            if event.status == "ready" || event.status == "error" {
                break
            }
        }

        let image = try await dbPool.read { db in try VMImage.fetchOne(db, key: imageID) }
        #expect(image?.status == "error", "Download with wrong SHA256 should fail")
        #expect(image?.error?.contains("SHA256 mismatch") ?? false)
        #expect(
            !FileManager.default.fileExists(atPath: dest.path),
            "File should be deleted on checksum mismatch",
        )
    }

    @Test func `download with correct SHA 512 succeeds`() async throws {
        let content = Data("hello world".utf8)
        let hash = SHA512.hash(data: content).compactMap { String(format: "%02x", $0) }.joined()

        let sourceFile = tmpDir.appendingPathComponent("source3.iso")
        try content.write(to: sourceFile)

        let now = iso8601.string(from: Date())
        let imageID = "img-sha512-ok"
        try await dbPool.write { db in
            let image = VMImage(
                id: imageID, name: "Test", imageType: "iso", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: sourceFile.absoluteString, createdAt: now, updatedAt: now,
            )
            try image.insert(db)
        }

        let dest = tmpDir.appendingPathComponent("dest3.iso")
        await downloader.start(
            imageID: imageID, url: sourceFile, destination: dest, expectedChecksum: .sha512(hash),
        )

        let stream = await downloader.progressStream(imageID: imageID)
        for await event in stream {
            if event.status == "ready" || event.status == "error" {
                break
            }
        }

        let image = try await dbPool.read { db in try VMImage.fetchOne(db, key: imageID) }
        #expect(image?.status == "ready", "Download with correct SHA512 should succeed")
    }

    @Test func `download with no checksum succeeds`() async throws {
        let content = Data("no checksum".utf8)
        let sourceFile = tmpDir.appendingPathComponent("source4.iso")
        try content.write(to: sourceFile)

        let now = iso8601.string(from: Date())
        let imageID = "img-no-checksum"
        try await dbPool.write { db in
            let image = VMImage(
                id: imageID, name: "Test", imageType: "iso", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: sourceFile.absoluteString, createdAt: now, updatedAt: now,
            )
            try image.insert(db)
        }

        let dest = tmpDir.appendingPathComponent("dest4.iso")
        await downloader.start(
            imageID: imageID, url: sourceFile, destination: dest, expectedChecksum: nil,
        )

        let stream = await downloader.progressStream(imageID: imageID)
        for await event in stream {
            if event.status == "ready" || event.status == "error" {
                break
            }
        }

        let image = try await dbPool.read { db in try VMImage.fetchOne(db, key: imageID) }
        #expect(image?.status == "ready", "Download without checksum should succeed")
    }
}
