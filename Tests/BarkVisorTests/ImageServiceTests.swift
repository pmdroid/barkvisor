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
}

private actor RecordingCatalogStartDownloader: ImageDownloadStarting {
    private(set) var startedIDs: [String] = []

    func start(
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum?,
    ) {
        startedIDs.append(imageID)
    }
}
