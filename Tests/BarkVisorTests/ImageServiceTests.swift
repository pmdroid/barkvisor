import GRDB
import XCTest
@testable import BarkVisorCore

final class ImageServiceTests: XCTestCase {
    private var dbPool: DatabasePool?
    private var tmpDir: URL?

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(dbPool)
    }

    override func tearDown() {
        dbPool = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - parseTusMetadata

    func testParseTusMetadataSinglePair() {
        let raw = "filename dWJ1bnR1Lmlzbw==" // "ubuntu.iso" in base64
        let result = ImageService.parseTusMetadata(raw)
        XCTAssertEqual(result["filename"], "ubuntu.iso")
    }

    func testParseTusMetadataMultiplePairs() {
        let raw = "filename dWJ1bnR1Lmlzbw==, filetype aW1hZ2UvaXNv" // "image/iso" in base64
        let result = ImageService.parseTusMetadata(raw)
        XCTAssertEqual(result["filename"], "ubuntu.iso")
        XCTAssertEqual(result["filetype"], "image/iso")
    }

    func testParseTusMetadataEmpty() {
        let result = ImageService.parseTusMetadata("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseTusMetadataInvalidBase64() {
        let raw = "filename not-valid-base64"
        let result = ImageService.parseTusMetadata(raw)
        XCTAssertNil(result["filename"], "Invalid base64 should not produce a value")
    }

    func testParseTusMetadataMissingValue() {
        let raw = "filename"
        let result = ImageService.parseTusMetadata(raw)
        XCTAssertTrue(result.isEmpty, "Missing value should be skipped")
    }

    // MARK: - finalizeTusUpload

    func testFinalizeTusUploadFailureMarksImageErrorAndDeletesUpload() async throws {
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

        do {
            try await ImageService.finalizeTusUpload(upload: upload, db: dbPool)
            XCTFail("Expected finalizeTusUpload to throw when the chunk file is missing")
        } catch {}

        let storedImage = try await dbPool.read { db in
            try VMImage.fetchOne(db, key: image.id)
        }
        let storedUpload = try await dbPool.read { db in
            try TusUpload.fetchOne(db, key: upload.id)
        }

        XCTAssertEqual(storedImage?.status, "error")
        XCTAssertNotNil(storedImage?.error)
        XCTAssertNil(storedUpload)
    }
}
