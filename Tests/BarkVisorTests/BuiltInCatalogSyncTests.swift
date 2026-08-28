import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct BuiltInCatalogSyncTests {
    @Test func `daily interval is 24 hours`() {
        #expect(BuiltInCatalogSync.intervalNanoseconds == 24 * 60 * 60 * 1_000_000_000)
        #expect(BuiltInCatalogSync.periodicTaskID == "catalog-sync")
        #expect(BuiltInCatalogSync.startupTaskID == "catalog-sync-startup")
    }

    @Test func `scheduleDaily registers the periodic task id`() async throws {
        let manager = BackgroundTaskManager()
        let (pool, tmp) = try makeCatalogDB()
        defer {
            Task { await manager.cancelAll() }
            try? FileManager.default.removeItem(at: tmp)
        }
        let service = RepositorySyncService(dbPool: pool)
        await BuiltInCatalogSync.scheduleDaily(backgroundTasks: manager, syncService: service)
        #expect(await manager.hasPeriodicTask(BuiltInCatalogSync.periodicTaskID))
        await manager.cancelAll()
        #expect(await manager.hasPeriodicTask(BuiltInCatalogSync.periodicTaskID) == false)
    }

    @Test func `startup submit returns without waiting for HTTP`() async throws {
        let (pool, tmp) = try makeCatalogDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try ImageRepository(
                id: "repo-images", name: "Official", url: HomeCatalogOrigin.githubImagesURL,
                isBuiltIn: true, repoType: "images", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let fetcher = SlowCatalogFetcher()
        let service = RepositorySyncService(dbPool: pool, fetcher: fetcher)
        let manager = BackgroundTaskManager()
        let started = Date()
        let id = await BuiltInCatalogSync.submitStartup(
            backgroundTasks: manager, syncService: service,
        )
        #expect(id == BuiltInCatalogSync.startupTaskID)
        #expect(Date().timeIntervalSince(started) < 0.5)
        var sawFetch = false
        for _ in 0 ..< 40 {
            if await fetcher.started {
                sawFetch = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(sawFetch)
        await manager.cancelAll()
    }

    @Test func `member built-in sync does not call GitHub`() async throws {
        let (pool, tmp) = try makeCatalogDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try ImageRepository(
                id: "repo-images", name: "Official", url: HomeCatalogOrigin.githubImagesURL,
                isBuiltIn: true, repoType: "images", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let lastGood = LastGoodCatalogStore(directory: tmp)
        try lastGood.save(repoType: "images", data: imagesJSON())
        let fetcher = RecordingCatalogFetcher()
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: lastGood,
            fetcher: fetcher,
            memberCatalogFetchDisabled: true,
        )
        await service.syncBuiltIns()
        #expect(await fetcher.urls.isEmpty)
        let slug = try await pool.read { db in
            try RepositoryImage.filter(Column("slug") == "ubuntu-24.04-arm64").fetchOne(db)?.slug
        }
        #expect(slug == "ubuntu-24.04-arm64")
    }

    @Test func `built-in lastSyncedAt is the latest timestamp`() throws {
        let (pool, tmp) = try makeCatalogDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = iso8601.string(from: Date())
        try pool.write { db in
            try ImageRepository(
                id: "a", name: "Images", url: HomeCatalogOrigin.githubImagesURL,
                isBuiltIn: true, repoType: "images", lastSyncedAt: "2026-08-01T00:00:00Z",
                lastError: nil, syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try ImageRepository(
                id: "b", name: "Templates", url: HomeCatalogOrigin.githubTemplatesURL,
                isBuiltIn: true, repoType: "templates", lastSyncedAt: "2026-08-28T12:00:00Z",
                lastError: nil, syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try ImageRepository(
                id: "c", name: "Custom", url: "https://example.com/custom.json",
                isBuiltIn: false, repoType: "images", lastSyncedAt: "2026-09-01T00:00:00Z",
                lastError: nil, syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let rolled = try pool.read { db in try ImageRepository.builtInLastSyncedAt(db) }
        #expect(rolled == "2026-08-28T12:00:00Z")
    }
}

struct TemplateDeployCatalogRetryTests {
    @Test func `missing catalog image syncs once then resolves`() async throws {
        let (pool, tmp) = try makeCatalogDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let host = PlatformCapabilities.hostArch
        let slug = "cloud-\(host)"
        let now = iso8601.string(from: Date())
        let templateId = UUID().uuidString
        try await pool.write { db in
            try VMTemplate(
                id: templateId, slug: "box", name: "Box", description: nil,
                category: "general", icon: "terminal", imageSlug: slug,
                cpuCount: 1, memoryMB: 512, diskSizeGB: 8, portForwards: "[]",
                networkMode: "nat", inputs: "[]", userDataTemplate: "",
                isBuiltIn: true, repositoryId: nil, createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let sync = InsertingCatalogSync(pool: pool, slug: slug, arch: host)
        let downloader = CatalogRetryDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(templateId: templateId, vmName: "retry-box", inputs: [:]),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
            catalogSync: sync,
        )
        guard case .downloading = result else {
            Issue.record("expected download after retry, got \(result)")
            return
        }
        #expect(await sync.calls == 1)
        #expect(await downloader.startedURLs.contains { $0.absoluteString.contains(slug) })
    }

    @Test func `recipe deploy does not sync the catalog`() async throws {
        let (pool, tmp) = try makeCatalogDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let host = PlatformCapabilities.hostArch
        let sync = InsertingCatalogSync(pool: pool, slug: "unused", arch: host)
        let downloader = CatalogRetryDownloader()
        _ = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "home-only",
                vmName: "recipe-box",
                inputs: [:],
                recipe: DeployRecipe(
                    name: "Box",
                    slug: "box",
                    inputs: [],
                    userDataTemplate: "",
                    cpuCount: 1,
                    memoryMB: 512,
                    diskSizeGB: 8,
                    architectures: [host],
                    image: DeployRecipeImage(
                        downloadUrl: "https://example.com/recipe.qcow2",
                        arch: host,
                        imageType: "cloud-image",
                        slug: "recipe-\(host)",
                    ),
                ),
            ),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
            catalogSync: sync,
        )
        #expect(await sync.calls == 0)
    }
}

private func makeCatalogDB() throws -> (DatabasePool, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    return (pool, tmp)
}

private func imagesJSON() -> Data {
    Data(
        """
        {
          "name": "official",
          "version": 1,
          "images": [
            {
              "slug": "ubuntu-24.04-arm64",
              "name": "Ubuntu",
              "description": null,
              "imageType": "qcow2",
              "arch": "arm64",
              "version": "24.04",
              "downloadUrl": "https://example.com/ubuntu.qcow2",
              "sizeBytes": 1,
              "sha256": "abc"
            }
          ]
        }
        """.utf8,
    )
}

private actor SlowCatalogFetcher: CatalogURLFetching {
    private(set) var started = false

    func fetch(url: URL) async throws -> Data {
        started = true
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return Data()
    }
}

private actor RecordingCatalogFetcher: CatalogURLFetching {
    private(set) var urls: [String] = []

    func fetch(url: URL) async throws -> Data {
        urls.append(url.absoluteString)
        throw BarkVisorError.repositorySyncFailed("network")
    }
}

private actor InsertingCatalogSync: BuiltInCatalogSyncing {
    private let pool: DatabasePool
    private let slug: String
    private let arch: String
    private(set) var calls = 0

    init(pool: DatabasePool, slug: String, arch: String) {
        self.pool = pool
        self.slug = slug
        self.arch = arch
    }

    func syncBuiltIns() async {
        calls += 1
        let now = iso8601.string(from: Date())
        try? await pool.write { db in
            let repoId = "built-in-images"
            if try ImageRepository.fetchOne(db, key: repoId) == nil {
                try ImageRepository(
                    id: repoId, name: "Official", url: HomeCatalogOrigin.githubImagesURL,
                    isBuiltIn: true, repoType: "images", lastSyncedAt: now, lastError: nil,
                    syncStatus: "idle", createdAt: now, updatedAt: now,
                ).insert(db)
            }
            try RepositoryImage(
                id: UUID().uuidString, repositoryId: repoId, slug: slug,
                name: "Cloud", description: nil, imageType: "cloud-image", arch: arch,
                version: "1", downloadUrl: "https://example.com/\(slug).qcow2", sizeBytes: 1,
            ).insert(db)
        }
    }
}

private actor CatalogRetryDownloader: ImageDownloadStarting {
    private(set) var startedURLs: [URL] = []

    func start(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum?,
        expectedStoredSha256: String?,
    ) {
        startedURLs.append(url)
    }
}
