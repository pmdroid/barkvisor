import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class DepotRetryTests {
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
            hostId: "depot-device",
            fingerprint: "aa",
            agentHost: "192.168.10.8",
            agentPort: 7_778,
        )
        try devices.upsert(
            hostId: "other-device",
            fingerprint: "bb",
            agentHost: "192.168.10.9",
            agentPort: 7_778,
        )
        client = FakeLibraryDepotClient()
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func setDepot() throws {
        try dbPool.write { db in
            try AppSetting(key: LibrarySettings.libraryDepotHostIdKey, value: "depot-device")
                .save(db, onConflict: .replace)
        }
    }

    private func liveAcquire() -> LibraryDepotAcquire {
        let fake = client
        return LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { _ in fake },
            awaitCopy: false,
        )
    }

    private func seedReadyRemote(id: String, source: String) {
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
                filename: "cloud.img",
            ),
        ]
    }

    private func request(_ source: String) -> LibraryDepotFetchRequest {
        LibraryDepotFetchRequest(
            sourceUrl: source,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            expectedChecksum: nil,
        )
    }

    private func waitUntilStatus(id: String, status: String) async throws -> VMImage {
        for _ in 0 ..< 80 {
            if let image = try await dbPool.read({ db in try VMImage.fetchOne(db, key: id) }),
               image.status == status {
                return image
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw BarkVisorError.timeout("depot row did not become \(status)")
    }

    private func fallbackCount() throws -> Int {
        try dbPool.read { db in
            try AuditEntry.order(Column("id")).fetchAll(db)
                .count { $0.action == "library.depot.fallback" }
        }
    }

    @Test func `retry skips depot after copy fail`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-retry.img"
        seedReadyRemote(id: "remote-retry", source: source)
        client.fetchError = BarkVisorError.timeout("copy failed")
        let live = liveAcquire()

        let first = await live.fetchMatching(request(source), db: dbPool)
        let pending = try #require(first)
        #expect(pending.status == "downloading")
        let failed = try await waitUntilStatus(id: pending.id, status: "error")
        #expect(LibraryDepotAcquire.isDepotCopyFailure(failed.error))

        let retry = await live.fetchMatching(request(source), db: dbPool)
        #expect(retry == nil)
        #expect(client.listedURLs == [source])
        #expect(client.fetchedIds == ["remote-retry"])
        let rows = try await dbPool.read { db in try VMImage.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].status == "error")
        #expect(try fallbackCount() == 2)
    }

    @Test func `internet error still uses depot`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-after-internet.img"
        seedReadyRemote(id: "remote-after-internet", source: source)
        let now = "2026-01-01T00:00:00Z"
        try await dbPool.write { db in
            try VMImage(
                id: "img-internet-error", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: nil, sizeBytes: nil, status: "error", error: "HTTP 500 from origin",
                sourceUrl: source, createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let fake = client
        let acquire = LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { _ in fake },
            awaitCopy: true,
        )
        let image = await acquire.fetchMatching(request(source), db: dbPool)
        let stored = try #require(image)
        #expect(stored.status == "ready")
        #expect(stored.id != "img-internet-error")
        #expect(client.listedURLs == [source])
        #expect(client.fetchedIds == ["remote-after-internet"])
    }

    @Test func `concurrent claims share one row`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-concurrent.img"
        seedReadyRemote(id: "remote-concurrent", source: source)
        let gate = FetchGate()
        client.fetchGate = gate
        let live = liveAcquire()
        let req = request(source)
        let pool = dbPool

        let images = try await withThrowingTaskGroup(of: VMImage?.self) { group in
            group.addTask { await live.fetchMatching(req, db: pool) }
            group.addTask { await live.fetchMatching(req, db: pool) }
            var rows: [VMImage?] = []
            for try await row in group {
                rows.append(row)
            }
            return rows
        }
        let a = try #require(images[0])
        let b = try #require(images[1])
        #expect(a.id == b.id)
        #expect(a.status == "downloading")
        #expect(b.status == "downloading")
        let count = try await dbPool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 1)

        gate.signal()
        gate.signal()
        let ready = try await waitUntilStatus(id: a.id, status: "ready")
        #expect(ready.status == "ready")
        #expect(client.fetchedIds == ["remote-concurrent"])
    }

    @Test func `orphaned downloading row falls back to internet`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-orphan.img"
        seedReadyRemote(id: "remote-orphan", source: source)
        let now = "2026-01-01T00:00:00Z"
        try await dbPool.write { db in
            try VMImage(
                id: "img-orphan", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading",
                error: LibraryDepotAcquire.depotCopyingMarker,
                sourceUrl: source, createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let retry = await liveAcquire().fetchMatching(request(source), db: dbPool)
        #expect(retry == nil)
        #expect(client.listedURLs.isEmpty)
        #expect(client.fetchedIds.isEmpty)
        let rows = try await dbPool.read { db in try VMImage.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].id == "img-orphan")
        #expect(rows[0].status == "error")
        #expect(LibraryDepotAcquire.isDepotCopyFailure(rows[0].error))
        #expect(try fallbackCount() == 1)
    }

    @Test func `internet downloading row is left for the downloader`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-internet-inflight.img"
        seedReadyRemote(id: "remote-internet-inflight", source: source)
        let now = "2026-01-01T00:00:00Z"
        try await dbPool.write { db in
            try VMImage(
                id: "img-inet", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: nil, sizeBytes: nil, status: "downloading", error: nil,
                sourceUrl: source, createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let image = await liveAcquire().fetchMatching(request(source), db: dbPool)
        let stored = try #require(image)
        #expect(stored.id == "img-inet")
        #expect(stored.status == "downloading")
        #expect(client.fetchedIds.isEmpty)
        let rows = try await dbPool.read { db in try VMImage.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].status == "downloading")
        #expect(rows[0].error == nil)
    }

    @Test func `deploy starts internet after orphaned depot row`() async throws {
        try setDepot()
        let host = PlatformCapabilities.hostArch
        let source = "https://example.com/cloud-deploy-orphan.img"
        seedReadyRemote(id: "remote-deploy-orphan", source: source)
        let now = "2026-01-01T00:00:00Z"
        let repoId = UUID().uuidString
        let templateId = UUID().uuidString
        let slug = "cloud-\(host)"
        try await dbPool.write { db in
            try ImageRepository(
                id: repoId, name: "test", url: "https://example.com/catalog.json",
                isBuiltIn: false, repoType: "templates", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try RepositoryImage(
                id: UUID().uuidString, repositoryId: repoId, slug: slug,
                name: "Cloud", description: nil, imageType: "cloud-image", arch: host,
                version: "1", downloadUrl: source, sizeBytes: 1_024,
            ).insert(db)
            try VMTemplate(
                id: templateId, slug: "orphan-deploy", name: "Orphan", description: nil,
                category: "general", icon: "terminal", imageSlug: slug,
                cpuCount: 1, memoryMB: 512, diskSizeGB: 8, portForwards: "[]",
                networkMode: "nat", inputs: "[]", userDataTemplate: "",
                isBuiltIn: false, repositoryId: repoId, createdAt: now, updatedAt: now,
                architecturesJson: #"["arm64","x86_64"]"#,
                imageByArchJson: #"{"arm64":"cloud-arm64","x86_64":"cloud-x86_64"}"#,
            ).insert(db)
            try VMImage(
                id: "img-deploy-orphan", name: "Cloud", imageType: "cloud-image", arch: host,
                path: nil, sizeBytes: nil, status: "downloading",
                error: LibraryDepotAcquire.depotCopyingMarker,
                sourceUrl: source, createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let downloader = RecordingCatalogDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(templateId: templateId, vmName: "orphan-vm", inputs: [:]),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: dbPool,
            depot: liveAcquire(),
        )
        guard case let .downloading(imageId) = result else {
            Issue.record("expected internet download after orphan, got \(result)")
            return
        }
        #expect(imageId != "img-deploy-orphan")
        let started = await downloader.startedURLs
        #expect(started == [URL(string: source)])
        let orphan = try await dbPool.read { db in try VMImage.fetchOne(db, key: "img-deploy-orphan") }
        #expect(orphan?.status == "error")
        #expect(LibraryDepotAcquire.isDepotCopyFailure(orphan?.error))
        #expect(client.listedURLs.isEmpty)
        #expect(client.fetchedIds.isEmpty)
    }

    @Test func `started depot failure starts internet on the same row`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-fallback-now.img"
        seedReadyRemote(id: "remote-fallback-now", source: source)
        client.fetchError = BarkVisorError.timeout("copy failed")
        let downloader = RecordingCatalogDownloader()
        let progress = RecordingProgress()
        let acquire = LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { [client] _ in client },
            awaitCopy: true,
            progress: progress,
            internetFallback: downloader,
        )

        let image = await acquire.fetchMatching(request(source), db: dbPool)
        #expect(image == nil)
        let started = await downloader.startedURLs
        #expect(started == [URL(string: source)])
        let rows = try await dbPool.read { db in try VMImage.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].status == "downloading")
        #expect(rows[0].error == nil)
        let events = await progress.events
        #expect(events.contains { $0.status == "downloading" })
        #expect(!events.contains { $0.status == "error" })

        let retry = await acquire.fetchMatching(request(source), db: dbPool)
        #expect(retry?.id == rows[0].id)
        #expect(retry?.status == "downloading")
        #expect(client.listedURLs == [source])
        #expect(client.fetchedIds == ["remote-fallback-now"])
    }

    @Test func `ready cache miss when catalog checksum differs`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-stale-checksum.img"
        seedReadyRemote(id: "remote-stale", source: source)
        let now = "2026-01-01T00:00:00Z"
        try await dbPool.write { db in
            try VMImage(
                id: "img-stale", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: "/tmp/stale.img", sizeBytes: 4, status: "ready", error: nil,
                sourceUrl: source, sha256: "aaa", createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let hashFile = tmpDir.appendingPathComponent("depot-hash.img")
        try client.bytes.write(to: hashFile)
        let digest = try ImageFileChecksum.sha256Hex(ofFile: hashFile)
        let req = LibraryDepotFetchRequest(
            sourceUrl: source,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            expectedChecksum: .sha256(digest),
        )
        let acquire = LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { [client] _ in client },
            awaitCopy: true,
        )
        let image = await acquire.fetchMatching(req, db: dbPool)
        let stored = try #require(image)
        #expect(stored.id != "img-stale")
        #expect(stored.status == "ready")
        #expect(client.fetchedIds == ["remote-stale"])
    }
}

private actor RecordingProgress: ImageProgressPublishing {
    private(set) var events: [ImageProgressEvent] = []

    func publish(_ event: ImageProgressEvent) {
        events.append(event)
    }
}

private actor RecordingCatalogDownloader: ImageDownloadStarting {
    private(set) var startedURLs: [URL] = []

    func start(
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum?,
    ) {
        startedURLs.append(url)
    }
}
