import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class ImageServiceTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - parseTusMetadata

    @Test func `parse tus metadata single pair`() {
        let raw = "filename dWJ1bnR1Lmlzbw==" // "ubuntu.iso" in base64
        let result = ImageService.parseTusMetadata(raw)
        #expect(result["filename"] == "ubuntu.iso")
    }

    @Test func `parse tus metadata multiple pairs`() {
        let raw = "filename dWJ1bnR1Lmlzbw==, filetype aW1hZ2UvaXNv" // "image/iso" in base64
        let result = ImageService.parseTusMetadata(raw)
        #expect(result["filename"] == "ubuntu.iso")
        #expect(result["filetype"] == "image/iso")
    }

    @Test func `parse tus metadata empty`() {
        let result = ImageService.parseTusMetadata("")
        #expect(result.isEmpty)
    }

    @Test func `parse tus metadata invalid base 64`() {
        let raw = "filename not-valid-base64"
        let result = ImageService.parseTusMetadata(raw)
        #expect(result["filename"] == nil, "Invalid base64 should not produce a value")
    }

    @Test func `parse tus metadata missing value`() {
        let raw = "filename"
        let result = ImageService.parseTusMetadata(raw)
        #expect(result.isEmpty, "Missing value should be skipped")
    }

    // MARK: - finalizeTusUpload

    @Test func `finalize tus upload failure marks image error and deletes upload`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let image = VMImage(
            id: "img-1",
            name: "Ubuntu",
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
        let upload = TusUpload(
            id: "upload-1",
            imageId: image.id,
            offset: 42,
            length: 42,
            metadata: "",
            chunkPath: tmpDir.appendingPathComponent("missing-upload.part").path,
            createdAt: now,
            updatedAt: now,
        )

        try await dbPool.write { db in
            try image.insert(db)
            try upload.insert(db)
        }

        await #expect(throws: (any Error).self) {
            try await ImageService.finalizeTusUpload(upload: upload, db: self.dbPool)
        }

        let storedImage = try await dbPool.read { db in
            try VMImage.fetchOne(db, key: image.id)
        }
        let storedUpload = try await dbPool.read { db in
            try TusUpload.fetchOne(db, key: upload.id)
        }

        #expect(storedImage?.status == "error")
        #expect(storedImage?.error != nil)
        #expect(storedUpload == nil)
    }

    @Test func `concurrent catalog downloads share one row`() async throws {
        let library = tmpDir.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try await dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
        }
        let downloader = RecordingCatalogStartDownloader()
        let source = "https://example.com/catalog-concurrent.img"
        let sourceURL = try #require(URL(string: source))
        let pool = dbPool

        let repoImage = RepositoryImage(
            id: "ri-concurrent", repositoryId: "repo-1", slug: "cloud",
            name: "Cloud", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: source, sizeBytes: nil,
        )
        let claims = try await withThrowingTaskGroup(of: CatalogDownloadClaim.self) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    try await ImageService.startOrDetectCatalogDownload(
                        repoImage: repoImage,
                        sourceURL: sourceURL,
                        checksum: nil,
                        downloader: downloader,
                        db: pool,
                    )
                }
            }
            var rows: [CatalogDownloadClaim] = []
            for try await claim in group {
                rows.append(claim)
            }
            return rows
        }

        #expect(claims.count == 2)
        #expect(claims[0].image.id == claims[1].image.id)
        #expect(claims[0].image.status == "downloading")
        let count = try await dbPool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 1)
        let started = await downloader.startedIDs
        #expect(started == [claims[0].image.id])
    }

    @Test func `catalog destination failure marks the claimed row so a later claim can retry`() async throws {
        let blocked = tmpDir.appendingPathComponent("not-a-library")
        try Data().write(to: blocked)
        try await dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: blocked.path)
                .save(db, onConflict: .replace)
        }
        let downloader = RecordingCatalogStartDownloader()
        let source = "https://example.com/catalog-dest-fail.img"
        let sourceURL = try #require(URL(string: source))
        let repoImage = RepositoryImage(
            id: "ri-dest-fail", repositoryId: "repo-1", slug: "cloud",
            name: "Cloud", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: source, sizeBytes: nil,
        )
        await #expect(throws: (any Error).self) {
            try await ImageService.startOrDetectCatalogDownload(
                repoImage: repoImage,
                sourceURL: sourceURL,
                checksum: nil,
                downloader: downloader,
                db: dbPool,
            )
        }
        let failed = try await dbPool.read { db in
            try VMImage.filter(Column("sourceUrl") == source).fetchOne(db)
        }
        #expect(failed?.status == "error")
        let started = await downloader.startedIDs
        #expect(started.isEmpty)

        let library = tmpDir.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try await dbPool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
        }
        let retry = try await ImageService.startOrDetectCatalogDownload(
            repoImage: repoImage,
            sourceURL: sourceURL,
            checksum: nil,
            downloader: downloader,
            db: dbPool,
        )
        #expect(retry.image.status == "downloading")
        #expect(retry.image.id != failed?.id)
        let startedAfter = await downloader.startedIDs
        #expect(startedAfter == [retry.image.id])
    }

    @Test func `ready image is ignored when catalog checksum differs`() throws {
        let now = "2026-01-01T00:00:00Z"
        let source = "https://example.com/cloud-checksum.img"
        try dbPool.write { db in
            try VMImage(
                id: "img-wrong-hash", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: "/tmp/cloud.img", sizeBytes: 4, status: "ready", error: nil,
                sourceUrl: source, sha256: "aaa", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let miss = try dbPool.read { db in
            try ImageService.readyImage(
                sourceUrl: source, expectedChecksum: .sha256("bbb"), db: db,
            )
        }
        #expect(miss == nil)
        let hit = try dbPool.read { db in
            try ImageService.readyImage(
                sourceUrl: source, expectedChecksum: .sha256("aaa"), db: db,
            )
        }
        #expect(hit?.id == "img-wrong-hash")
    }

    @Test func `compressed ready image verifies recorded digest not catalog hash`() throws {
        let now = "2026-01-01T00:00:00Z"
        let file = tmpDir.appendingPathComponent("cloud.img")
        let content = Data("decompressed-cloud".utf8)
        try content.write(to: file)
        let digest = try ImageFileChecksum.sha256Hex(ofFile: file)
        let source = "https://cdn.example/cloud.img.xz?token=abc"
        try dbPool.write { db in
            try VMImage(
                id: "img-xz", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: file.path, sizeBytes: Int64(content.count), status: "ready", error: nil,
                sourceUrl: source, sha256: digest, createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let catalogHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let hit = try dbPool.read { db in
            try ImageService.readyImage(
                sourceUrl: source, expectedChecksum: .sha256(catalogHash), db: db,
            )
        }
        #expect(hit?.id == "img-xz")

        try Data("tampered".utf8).write(to: file)
        let miss = try dbPool.read { db in
            try ImageService.readyImage(
                sourceUrl: source, expectedChecksum: .sha256(catalogHash), db: db,
            )
        }
        #expect(miss == nil)
    }

    @Test func `compressed ready image without recorded digest is not reused`() throws {
        let now = "2026-01-01T00:00:00Z"
        let source = "https://example.com/cloud.img.gz"
        try dbPool.write { db in
            try VMImage(
                id: "img-gz-nodigest", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: "/tmp/missing-cloud.img", sizeBytes: 4, status: "ready", error: nil,
                sourceUrl: source, sha256: nil, createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let miss = try dbPool.read { db in
            try ImageService.readyImage(
                sourceUrl: source, expectedChecksum: .sha256("bbbbbbbb"), db: db,
            )
        }
        #expect(miss == nil)
    }

    @Test func `start download rejects private URL before inserting`() async throws {
        let pool = dbPool
        let downloader = ImageDownloader(dbPool: { pool })
        await #expect(throws: BarkVisorError.self) {
            try await ImageService.startDownload(
                ImageDownloadRequest(
                    name: "evil",
                    url: "http://127.0.0.1/cloud.iso",
                    imageType: "iso",
                    arch: "arm64",
                ),
                downloader: downloader,
                db: pool,
            )
        }
        let count = try await pool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 0)
    }

    @Test func `catalog download rejects file URL without starting`() async throws {
        let downloader = RecordingCatalogStartDownloader()
        let source = "file://cloud-images.ubuntu.com/etc/passwd"
        let sourceURL = try #require(URL(string: source))
        #expect(sourceURL.isFileURL)
        let repoImage = RepositoryImage(
            id: "ri-file", repositoryId: "repo-1", slug: "cloud",
            name: "Cloud", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: source, sizeBytes: nil,
        )
        let pool = dbPool
        await #expect(throws: BarkVisorError.self) {
            try await ImageService.startOrDetectCatalogDownload(
                repoImage: repoImage,
                sourceURL: sourceURL,
                checksum: nil,
                downloader: downloader,
                db: pool,
            )
        }
        let count = try await pool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 0)
        let started = await downloader.startedIDs
        #expect(started.isEmpty)
    }

    @Test func `catalog download rejects ftp URL without starting`() async throws {
        let downloader = RecordingCatalogStartDownloader()
        let source = "ftp://cloud-images.ubuntu.com/releases/a.img"
        let sourceURL = try #require(URL(string: source))
        let repoImage = RepositoryImage(
            id: "ri-ftp", repositoryId: "repo-1", slug: "cloud",
            name: "Cloud", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: source, sizeBytes: nil,
        )
        let pool = dbPool
        await #expect(throws: BarkVisorError.self) {
            try await ImageService.startOrDetectCatalogDownload(
                repoImage: repoImage,
                sourceURL: sourceURL,
                checksum: nil,
                downloader: downloader,
                db: pool,
            )
        }
        let count = try await pool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 0)
        let started = await downloader.startedIDs
        #expect(started.isEmpty)
    }

    @Test func `catalog download rejects private URL without starting`() async throws {
        let downloader = RecordingCatalogStartDownloader()
        let source = "http://169.254.169.254/latest/cloud.img"
        let sourceURL = try #require(URL(string: source))
        let repoImage = RepositoryImage(
            id: "ri-ssrf", repositoryId: "repo-1", slug: "cloud",
            name: "Cloud", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: source, sizeBytes: nil,
        )
        let pool = dbPool
        await #expect(throws: BarkVisorError.self) {
            try await ImageService.startOrDetectCatalogDownload(
                repoImage: repoImage,
                sourceURL: sourceURL,
                checksum: nil,
                downloader: downloader,
                db: pool,
            )
        }
        let count = try await pool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 0)
        let started = await downloader.startedIDs
        #expect(started.isEmpty)
    }
}

private actor RecordingCatalogStartDownloader: ImageDownloadStarting {
    private(set) var startedIDs: [String] = []

    func start(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum?,
        expectedStoredSha256: String?,
    ) {
        startedIDs.append(imageID)
    }
}
