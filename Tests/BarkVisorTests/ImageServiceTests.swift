import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite final class ImageServiceTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

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
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - parseTusMetadata

    @Test func parseTusMetadataSinglePair() {
        let raw = "filename dWJ1bnR1Lmlzbw==" // "ubuntu.iso" in base64
        let result = ImageService.parseTusMetadata(raw)
        #expect(result["filename"] == "ubuntu.iso")
    }

    @Test func parseTusMetadataMultiplePairs() {
        let raw = "filename dWJ1bnR1Lmlzbw==, filetype aW1hZ2UvaXNv" // "image/iso" in base64
        let result = ImageService.parseTusMetadata(raw)
        #expect(result["filename"] == "ubuntu.iso")
        #expect(result["filetype"] == "image/iso")
    }

    @Test func parseTusMetadataEmpty() {
        let result = ImageService.parseTusMetadata("")
        #expect(result.isEmpty)
    }

    @Test func parseTusMetadataInvalidBase64() {
        let raw = "filename not-valid-base64"
        let result = ImageService.parseTusMetadata(raw)
        #expect(result["filename"] == nil, "Invalid base64 should not produce a value")
    }

    @Test func parseTusMetadataMissingValue() {
        let raw = "filename"
        let result = ImageService.parseTusMetadata(raw)
        #expect(result.isEmpty, "Missing value should be skipped")
    }

    // MARK: - finalizeTusUpload

    @Test func finalizeTusUploadFailureMarksImageErrorAndDeletesUpload() async throws {
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
}
