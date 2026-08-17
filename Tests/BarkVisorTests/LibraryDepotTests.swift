#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

private func waitUntilImageStatus(id: String, status: String, db: DatabasePool) async throws -> VMImage {
    for _ in 0 ..< 80 {
        if let image = try await db.read({ db in try VMImage.fetchOne(db, key: id) }),
           image.status == status {
            return image
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw BarkVisorError.timeout("depot row did not become \(status)")
}

final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if permits > 0 {
                permits -= 1
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume()
        } else {
            permits += 1
            lock.unlock()
        }
    }
}

final class FakeLibraryDepotClient: LibraryDepotClient, @unchecked Sendable {
    private let lock = NSLock()
    var images: [LibraryDepotImageInfo] = []
    var bytes = Data("depot-bytes".utf8)
    var listError: Error?
    var fetchError: Error?
    private var listed: [String] = []
    private var fetched: [String] = []
    var reportedSha256: String?
    var fetchGate: FetchGate?

    var listedURLs: [String] {
        snapshotListed()
    }

    var fetchedIds: [String] {
        snapshotFetched()
    }

    func listImages(sourceUrl: String) async throws -> [LibraryDepotImageInfo] {
        let snapshot = recordList(sourceUrl)
        if let listError = snapshot.0 { throw listError }
        return snapshot.1.filter { $0.sourceUrl == sourceUrl || $0.sourceUrl == nil }
    }

    func fetchBytes(imageId: String, to destination: URL) async throws -> LibraryDepotFetchBytes {
        let snapshot = recordFetch(imageId)
        if let fetchError = snapshot.0 { throw fetchError }
        if let gate = snapshot.1 {
            await gate.wait()
        }
        let bytes = snapshot.2
        try bytes.write(to: destination)
        let sha = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        return LibraryDepotFetchBytes(
            sha256: sha,
            bytesWritten: Int64(bytes.count),
            filename: "cloud.img",
            reportedSha256: snapshot.3 ?? sha,
        )
    }

    private func snapshotListed() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    private func snapshotFetched() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetched
    }

    private func recordList(_ sourceUrl: String) -> (Error?, [LibraryDepotImageInfo]) {
        lock.lock()
        defer { lock.unlock() }
        listed.append(sourceUrl)
        return (listError, images)
    }

    private func recordFetch(
        _ imageId: String,
    ) -> (Error?, FetchGate?, Data, String?) {
        lock.lock()
        defer { lock.unlock() }
        fetched.append(imageId)
        return (fetchError, fetchGate, bytes, reportedSha256)
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
            awaitCopy: true,
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private static func cloudRequest(
        sourceUrl: String = "https://example.com/cloud.img",
        expectedChecksum: ExpectedChecksum? = nil,
    ) -> LibraryDepotFetchRequest {
        LibraryDepotFetchRequest(
            sourceUrl: sourceUrl,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            expectedChecksum: expectedChecksum,
        )
    }

    private func seedReadyRemote(id: String, source: String, filename: String = "cloud.img") {
        client.images = [
            LibraryDepotImageInfo(
                id: id,
                name: "Cloud",
                imageType: "cloud-image",
                arch: "arm64",
                status: "ready",
                sizeBytes: Int64(client.bytes.count),
                sourceUrl: source,
                sha256: nil,
                slug: "ubuntu",
                filename: filename,
            ),
        ]
    }

    private func waitUntilReady(id: String) async throws -> VMImage {
        try await waitUntilImageStatus(id: id, status: "ready", db: dbPool)
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
        seedReadyRemote(id: "remote-1", source: source)

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
        seedReadyRemote(id: "remote-bad", source: source)
        client.reportedSha256 = "0000000000000000000000000000000000000000000000000000000000000000"

        let image = await acquire.fetchMatching(Self.cloudRequest(sourceUrl: source), db: dbPool)
        #expect(image == nil)
        #expect(try auditActions() == ["library.depot.fallback"])
        let library = tmpDir.appendingPathComponent("library")
        let files = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(!files.contains { $0.hasSuffix(".img") || $0.hasSuffix(".img.part") })
    }

    @Test func `uncompressed catalog checksum mismatch falls back`() async throws {
        try setDepot("depot-device")
        let source = "https://example.com/cloud.img"
        seedReadyRemote(id: "remote-catalog", source: source)
        let image = await acquire.fetchMatching(
            Self.cloudRequest(
                sourceUrl: source,
                expectedChecksum: .sha256(
                    "0000000000000000000000000000000000000000000000000000000000000000",
                ),
            ),
            db: dbPool,
        )
        #expect(image == nil)
        #expect(try auditActions() == ["library.depot.fallback"])
    }

    @Test func `compressed source skips catalog checksum and keeps depot digest`() async throws {
        try setDepot("depot-device")
        let source = "https://example.com/cloud.img.xz?token=abc&exp=1"
        seedReadyRemote(id: "remote-xz", source: source, filename: "cloud.img")
        let image = await acquire.fetchMatching(
            Self.cloudRequest(
                sourceUrl: source,
                expectedChecksum: .sha256(
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            ),
            db: dbPool,
        )
        let stored = try #require(image)
        #expect(stored.status == "ready")
        let digest = SHA256.hash(data: client.bytes).compactMap { String(format: "%02x", $0) }.joined()
        #expect(stored.sha256 == digest)
        #expect(try auditActions() == ["library.depot.fetch"])
    }

    @Test func `fetchMatching returns downloading before the copy finishes`() async throws {
        try setDepot("depot-device")
        let source = "https://example.com/cloud.img"
        seedReadyRemote(id: "remote-slow", source: source)
        let gate = FetchGate()
        client.fetchGate = gate
        let fake = client
        let live = LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { _ in fake },
            awaitCopy: false,
        )
        let pool = dbPool
        let image = try await withThrowingTaskGroup(of: VMImage?.self) { group in
            group.addTask {
                await live.fetchMatching(Self.cloudRequest(sourceUrl: source), db: pool)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                throw BarkVisorError.timeout("fetchMatching blocked on depot copy")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let stored = try #require(image)
        #expect(stored.status == "downloading")
        let pending = try await dbPool.read { db in try VMImage.fetchOne(db, key: stored.id) }
        #expect(pending?.status == "downloading")
        #expect(pending?.path == nil)
        gate.signal()
        let ready = try await waitUntilReady(id: stored.id)
        #expect(ready.status == "ready")
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

struct LibraryDepotStreamLimitsTests {
    @Test func `write cap honors content length and max bytes`() throws {
        #expect(try LibraryDepotStreamLimits.writeCap(contentLength: 100, maxBytes: 1_000) == 100)
        #expect(try LibraryDepotStreamLimits.writeCap(contentLength: nil, maxBytes: 1_000) == 1_000)
        #expect(throws: BarkVisorError.self) {
            try LibraryDepotStreamLimits.writeCap(contentLength: 2_000, maxBytes: 1_000)
        }
        #expect(throws: BarkVisorError.self) {
            try LibraryDepotStreamLimits.writeCap(contentLength: -1, maxBytes: 1_000)
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

    @Test func `sourceUrl query encodes ampersand and equals`() throws {
        let source = "https://cdn.example/cloud.img.xz?token=abc&exp=1"
        let query = LibraryDepotHTTP.sourceUrlQuery(source)
        #expect(query.hasPrefix("sourceUrl="))
        let encoded = String(query.dropFirst("sourceUrl=".count))
        #expect(!encoded.contains("&"))
        #expect(encoded.contains("%26"))
        #expect(encoded.contains("%3D"))
        let url = try HomeDeviceProxy.memberURL(
            host: "192.168.1.9",
            port: 7_778,
            path: LibraryDepotHTTP.listPath,
            query: query,
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.count == 1)
        #expect(items?.first?.name == "sourceUrl")
        #expect(items?.first?.value == source)
        #expect(ImageService.isCompressedSource(source))
        #expect(!ImageService.isCompressedSource("https://example.com/cloud.img"))
    }
}
