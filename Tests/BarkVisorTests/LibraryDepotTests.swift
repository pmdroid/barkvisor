#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class FakeLibraryDepotClient: LibraryDepotClient, @unchecked Sendable {
    var images: [LibraryDepotImageInfo] = []
    var bytes = Data("depot-bytes".utf8)
    var listError: Error?
    var fetchError: Error?
    var listedURLs: [String] = []
    var fetchedIds: [String] = []
    var reportedSha256: String?

    func listImages(sourceUrl: String) async throws -> [LibraryDepotImageInfo] {
        listedURLs.append(sourceUrl)
        if let listError { throw listError }
        return images.filter { $0.sourceUrl == sourceUrl || $0.sourceUrl == nil }
    }

    func fetchBytes(imageId: String, to destination: URL) async throws -> LibraryDepotFetchBytes {
        fetchedIds.append(imageId)
        if let fetchError { throw fetchError }
        try bytes.write(to: destination)
        let sha = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        return LibraryDepotFetchBytes(
            sha256: sha,
            bytesWritten: Int64(bytes.count),
            filename: "cloud.img",
            reportedSha256: reportedSha256 ?? sha,
        )
    }
}

final class LibraryDepotTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let devices: DeviceRegistry
    private let client: FakeLibraryDepotClient
    private let acquire: LibraryDepotAcquire
    private let localHostId = "self-device"

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

        devices = DeviceRegistry(dataDir: tmp)
        try devices.upsert(
            hostId: "depot-device",
            fingerprint: "aa",
            agentHost: "192.168.10.8",
            agentPort: 7_778,
        )
        client = FakeLibraryDepotClient()
        let fake = client
        acquire = LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmp,
            devices: devices,
            openClient: { _ in fake },
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private static func cloudRequest(
        sourceUrl: String = "https://example.com/cloud.img",
    ) -> LibraryDepotFetchRequest {
        LibraryDepotFetchRequest(
            sourceUrl: sourceUrl,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            expectedChecksum: nil,
        )
    }

    private func setDepot(_ hostId: String?) throws {
        try dbPool.write { db in
            if let hostId {
                try AppSetting(key: LibrarySettings.libraryDepotHostIdKey, value: hostId)
                    .save(db, onConflict: .replace)
            } else {
                _ = try AppSetting.deleteOne(db, key: LibrarySettings.libraryDepotHostIdKey)
            }
        }
    }

    private func auditActions() throws -> [String] {
        try dbPool.read { db in
            try AuditEntry.order(Column("id")).fetchAll(db).map(\.action)
        }
    }

    @Test func `unset depot skips without audit`() async throws {
        let image = await acquire.fetchMatching(Self.cloudRequest(), db: dbPool)
        #expect(image == nil)
        #expect(client.listedURLs.isEmpty)
        #expect(try auditActions().isEmpty)
    }

    @Test func `self depot skips without fetching`() async throws {
        try setDepot(localHostId)
        let image = await acquire.fetchMatching(Self.cloudRequest(), db: dbPool)
        #expect(image == nil)
        #expect(client.listedURLs.isEmpty)
        #expect(try auditActions().isEmpty)
    }

    @Test func `successful depot fetch writes local Library row`() async throws {
        try setDepot("depot-device")
        let source = "https://example.com/cloud.img"
        client.images = [
            LibraryDepotImageInfo(
                id: "remote-1",
                name: "Cloud",
                imageType: "cloud-image",
                arch: "arm64",
                status: "ready",
                sizeBytes: Int64(client.bytes.count),
                sourceUrl: source,
                sha256: nil,
                slug: "ubuntu",
                filename: "cloud.img",
            ),
        ]

        let image = await acquire.fetchMatching(Self.cloudRequest(sourceUrl: source), db: dbPool)
        let stored = try #require(image)
        #expect(stored.status == "ready")
        #expect(stored.sourceUrl == source)
        let storedPath = try #require(stored.path)
        #expect(FileManager.default.fileExists(atPath: storedPath))
        #expect(client.fetchedIds == ["remote-1"])
        #expect(try auditActions() == ["library.depot.fetch"])
        let digest = try ImageFileChecksum.sha256Hex(ofFile: URL(fileURLWithPath: storedPath))
        #expect(stored.sha256 == digest)
    }

    @Test func `depot down falls back and is audit logged`() async throws {
        try setDepot("depot-device")
        client.listError = BarkVisorError.timeout("depot down")
        let image = await acquire.fetchMatching(Self.cloudRequest(), db: dbPool)
        #expect(image == nil)
        #expect(client.fetchedIds.isEmpty)
        #expect(try auditActions() == ["library.depot.fallback"])
        let rows = try await dbPool.read { db in try VMImage.fetchCount(db) }
        #expect(rows == 0)
    }

    @Test func `checksum mismatch falls back and deletes bytes`() async throws {
        try setDepot("depot-device")
        let source = "https://example.com/cloud.img"
        client.images = [
            LibraryDepotImageInfo(
                id: "remote-bad",
                name: "Cloud",
                imageType: "cloud-image",
                arch: "arm64",
                status: "ready",
                sizeBytes: 4,
                sourceUrl: source,
                sha256: nil,
                slug: nil,
                filename: "cloud.img",
            ),
        ]
        client.reportedSha256 = "0000000000000000000000000000000000000000000000000000000000000000"

        let image = await acquire.fetchMatching(Self.cloudRequest(sourceUrl: source), db: dbPool)
        #expect(image == nil)
        #expect(try auditActions() == ["library.depot.fallback"])
        let library = tmpDir.appendingPathComponent("library")
        let files = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(!files.contains { $0.hasSuffix(".img") || $0.hasSuffix(".img.part") })
    }

    @Test func `catalog listing exposes slug name arch size sha256`() throws {
        let file = tmpDir.appendingPathComponent("ready.img")
        let payload = Data("listed".utf8)
        try payload.write(to: file)
        let digest = try ImageFileChecksum.sha256Hex(ofFile: file)
        let now = "2026-01-01T00:00:00Z"
        try dbPool.write { db in
            try ImageRepository(
                id: "repo-1", name: "Test", url: "https://example.com/repo.json",
                isBuiltIn: false, repoType: "images", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try RepositoryImage(
                id: "ri-1", repositoryId: "repo-1", slug: "ubuntu-24",
                name: "Ubuntu", description: nil, imageType: "cloud-image", arch: "arm64",
                version: "1", downloadUrl: "https://example.com/ubuntu.img",
                sizeBytes: 6, sha256: digest,
            ).insert(db)
            try VMImage(
                id: "img-ready", name: "Ubuntu", imageType: "cloud-image", arch: "arm64",
                path: file.path, sizeBytes: 6, status: "ready", error: nil,
                sourceUrl: "https://example.com/ubuntu.img", sha256: digest,
                createdAt: now, updatedAt: now,
            ).insert(db)
            try VMImage(
                id: "img-dl", name: "Partial", imageType: "cloud-image", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: "https://example.com/other.img", createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let listed = try dbPool.read { db in
            try LibraryDepotCatalog.list(db: db, sourceUrl: "https://example.com/ubuntu.img")
        }
        #expect(listed.count == 1)
        #expect(listed[0].slug == "ubuntu-24")
        #expect(listed[0].name == "Ubuntu")
        #expect(listed[0].arch == "arm64")
        #expect(listed[0].sizeBytes == 6)
        #expect(listed[0].sha256 == digest)
        #expect(listed[0].filename == "ready.img")
    }

    @Test func `validateDepotHostId accepts paired Device and self`() throws {
        #expect(try LibrarySettings.validateDepotHostId(nil, localHostId: localHostId, devices: devices) == nil)
        #expect(try LibrarySettings.validateDepotHostId("  ", localHostId: localHostId, devices: devices) == nil)
        #expect(
            try LibrarySettings.validateDepotHostId(
                localHostId, localHostId: localHostId, devices: devices,
            ) == localHostId,
        )
        #expect(
            try LibrarySettings.validateDepotHostId(
                "depot-device", localHostId: localHostId, devices: devices,
            ) == "depot-device",
        )
        #expect(throws: BarkVisorError.self) {
            try LibrarySettings.validateDepotHostId(
                "unknown", localHostId: localHostId, devices: devices,
            )
        }
    }
}

struct LibraryDepotHTTPTests {
    @Test func `content path is distinct from the Home proxy`() {
        #expect(LibraryDepotHTTP.isImageBytesPath("/api/agent/library/images/img-1/content"))
        #expect(!LibraryDepotHTTP.isImageBytesPath("/api/agent/library/images"))
        #expect(!LibraryDepotHTTP.isImageBytesPath("/api/images/img-1"))
        #expect(
            LibraryDepotHTTP.contentPath(id: "img-1") == "/api/agent/library/images/img-1/content",
        )
    }
}
