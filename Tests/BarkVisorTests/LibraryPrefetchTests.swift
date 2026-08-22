#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct LibraryPrefetchTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let devices: DeviceRegistry
    private let client: FakeLibraryDepotClient
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
            hostId: "peer-device",
            fingerprint: "aa",
            agentHost: "192.168.10.8",
            agentPort: 7_778,
        )
        client = FakeLibraryDepotClient()
        client.bytes = Data("prefetch-bytes".utf8)
    }

    private func service() -> LibraryPrefetch {
        let fake = client
        return LibraryPrefetch(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { _ in fake },
            awaitCopy: true,
        )
    }

    private func request(sha: String? = nil) -> ImagePrefetchRequest {
        ImagePrefetchRequest(
            sourceHostId: "peer-device",
            sourceImageId: "remote-1",
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            sourceUrl: "https://example.invalid/cloud.img",
            sha256: sha,
        )
    }

    @Test func `prefetch copies bytes from another Device onto this Device`() async throws {
        let image = try await service().start(request(), db: dbPool)
        #expect(image.status == "ready")
        #expect(image.name == "Cloud")
        #expect(client.fetchedIds == ["remote-1"])
        #expect(FileManager.default.fileExists(atPath: image.path ?? ""))
        let digest = SHA256.hash(data: Data("prefetch-bytes".utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        #expect(image.sha256 == digest)
    }

    @Test func `prefetch of a local ready row is a no-op`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let local = VMImage(
            id: "local-1", name: "Cloud", imageType: "cloud-image", arch: "arm64",
            path: tmpDir.appendingPathComponent("local.img").path, sizeBytes: 4,
            status: "ready", error: nil, sourceUrl: nil, sha256: "abc",
            createdAt: now, updatedAt: now,
        )
        try await dbPool.write { db in try local.insert(db) }
        let image = try await service().start(
            ImagePrefetchRequest(
                sourceHostId: localHostId,
                sourceImageId: "local-1",
                name: "Cloud",
                imageType: "cloud-image",
                arch: "arm64",
            ),
            db: dbPool,
        )
        #expect(image.id == "local-1")
        #expect(client.fetchedIds.isEmpty)
    }

    @Test func `second prefetch with the same checksum reuses the ready row`() async throws {
        let first = try await service().start(request(), db: dbPool)
        let second = try await service().start(request(sha: first.sha256), db: dbPool)
        #expect(second.id == first.id)
        #expect(client.fetchedIds == ["remote-1"])
    }

    @Test func `unpaired source Device is not found`() async throws {
        let missing = ImagePrefetchRequest(
            sourceHostId: "nobody",
            sourceImageId: "img",
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
        )
        await #expect(throws: BarkVisorError.self) {
            try await service().start(missing, db: dbPool)
        }
    }
}
