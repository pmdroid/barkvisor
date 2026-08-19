#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// In-memory catalog bytes. Stands in for the internet adapter in unit tests.
private struct MemoryLibrarySource: LibraryByteSource {
    var bytes: Data
    var reportedSha256: String?

    func copyBytes(to destination: URL) async throws -> LibraryFetchedBytes {
        try bytes.write(to: destination)
        let sha = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        return LibraryFetchedBytes(
            sha256: sha,
            bytesWritten: Int64(bytes.count),
            reportedSha256: reportedSha256 ?? sha,
        )
    }
}

final class LibraryAcquireTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(pool)
        let library = tmp.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try pool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
        }
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func request(
        _ source: String,
        expectedChecksum: ExpectedChecksum? = nil,
    ) -> LibraryDepotFetchRequest {
        LibraryDepotFetchRequest(
            sourceUrl: source,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            expectedChecksum: expectedChecksum,
        )
    }

    @Test func `depot and internet adapters share claim verify persist`() async throws {
        let bytes = Data("shared-acquire-bytes".utf8)
        let digest = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        let internetSource = "https://example.com/shared-internet.img"
        let depotSource = "https://example.com/shared-depot.img"

        let internetReq = request(internetSource, expectedChecksum: .sha256(digest))
        let internetClaim = try await LibraryAcquire.claim(
            request: internetReq, kind: .internet, db: dbPool,
        )
        guard case let .started(internetRow) = internetClaim else {
            Issue.record("expected internet claim to start, got \(internetClaim)")
            return
        }
        let internetReady = try await LibraryAcquire.finish(
            imageId: internetRow.id,
            source: MemoryLibrarySource(bytes: bytes),
            request: internetReq,
            kind: .internet,
            db: dbPool,
        )
        #expect(internetReady.status == "ready")
        #expect(internetReady.sha256 == digest)
        #expect(internetReady.sourceUrl == internetSource)

        let client = FakeLibraryDepotClient()
        client.bytes = bytes
        let depotReq = request(depotSource, expectedChecksum: .sha256(digest))
        let depotClaim = try await LibraryAcquire.claim(
            request: depotReq, kind: .depot, db: dbPool,
        )
        guard case let .started(depotRow) = depotClaim else {
            Issue.record("expected depot claim to start, got \(depotClaim)")
            return
        }
        let depotReady = try await LibraryAcquire.finish(
            imageId: depotRow.id,
            source: DepotLibrarySource(client: client, remoteImageId: "remote-shared"),
            request: depotReq,
            kind: .depot,
            db: dbPool,
        )
        #expect(depotReady.status == "ready")
        #expect(depotReady.sha256 == digest)
        #expect(depotReady.sourceUrl == depotSource)
        #expect(client.fetchedIds == ["remote-shared"])

        let internetStored = try await dbPool.read { db in
            try VMImage.fetchOne(db, key: internetRow.id)
        }
        let depotStored = try await dbPool.read { db in
            try VMImage.fetchOne(db, key: depotRow.id)
        }
        #expect(internetStored?.status == depotStored?.status)
        #expect(internetStored?.sha256 == depotStored?.sha256)
        #expect(internetStored?.path != nil)
        #expect(depotStored?.path != nil)
        #expect(LibraryAcquire.hasLive(depotRow.id) == true)
        LibraryAcquire.endLive(depotRow.id)
    }

    @Test func `concurrent claims share one row for both kinds`() async throws {
        let source = "https://example.com/shared-claim.img"
        let req = request(source)
        let pool = dbPool
        let claims = try await withThrowingTaskGroup(of: LibraryAcquire.Claim.self) { group in
            group.addTask { try await LibraryAcquire.claim(request: req, kind: .internet, db: pool) }
            group.addTask { try await LibraryAcquire.claim(request: req, kind: .depot, db: pool) }
            var rows: [LibraryAcquire.Claim] = []
            for try await claim in group {
                rows.append(claim)
            }
            return rows
        }
        #expect(claims.count == 2)
        let ids = claims.map(\.imageId)
        #expect(ids[0] == ids[1])
        let count = try await dbPool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 1)
        if case let .started(image) = claims.first(where: {
            if case .started = $0 { return true }
            return false
        }) {
            LibraryAcquire.endLive(image.id)
        }
    }

    @Test func `catalog checksum pick prefers sha256`() {
        let image = RepositoryImage(
            id: "ri-1", repositoryId: "repo-1", slug: "cloud",
            name: "Cloud", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: "https://example.com/cloud.img", sizeBytes: 1,
            sha256: "aaa", sha512: "bbb",
        )
        #expect(ExpectedChecksum.catalog(from: image) == .sha256("aaa"))
        #expect(ExpectedChecksum.catalog(sha256: nil, sha512: "bbb") == .sha512("bbb"))
        #expect(ExpectedChecksum.catalog(sha256: "", sha512: "") == nil)
    }
}

extension LibraryAcquire.Claim {
    fileprivate var imageId: String? {
        switch self {
        case let .ready(image), let .inFlight(image), let .started(image):
            image.id
        case .sourceFailed:
            nil
        }
    }
}
