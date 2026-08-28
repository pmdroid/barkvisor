import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct HomeCatalogDistributionTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pool(in dir: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }

    private func insertRepo(
        _ pool: DatabasePool,
        url: String,
        repoType: String,
        isBuiltIn: Bool = true,
    ) async throws -> String {
        let id = UUID().uuidString
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try ImageRepository(
                id: id, name: "repo-\(repoType)", url: url,
                isBuiltIn: isBuiltIn, repoType: repoType, lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        return id
    }

    private func templatesJSON() -> Data {
        Data(
            """
            {
              "version": 1,
              "templates": [
                {
                  "slug": "ok-box",
                  "name": "Ok Box",
                  "category": "general",
                  "icon": "terminal",
                  "imageSlug": "ubuntu-24.04-arm64",
                  "cpuCount": 1,
                  "memoryMB": 512,
                  "diskSizeGB": 8,
                  "portForwards": [],
                  "networkMode": "nat",
                  "inputs": [],
                  "userDataTemplate": "#cloud-config\\n"
                }
              ]
            }
            """.utf8,
        )
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

    @Test func `member seed uses agent origin not GitHub`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        try Seeder.seedDefaultRepository(db: pool, isMember: true)
        let repos = try pool.read { try ImageRepository.fetchAll($0) }
        #expect(repos.contains { $0.repoType == "images" && $0.url == HomeCatalogOrigin.memberImagesURL })
        #expect(repos.contains { $0.repoType == "templates" && $0.url == HomeCatalogOrigin.memberTemplatesURL })
        #expect(!repos.contains { HomeCatalogOrigin.isGitHubBuiltIn($0.url) })
    }

    @Test func `home seed still uses GitHub URLs`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        try Seeder.seedDefaultRepository(db: pool, isMember: false)
        let repos = try pool.read { try ImageRepository.fetchAll($0) }
        #expect(repos.contains { $0.repoType == "images" && $0.url == HomeCatalogOrigin.githubImagesURL })
        #expect(repos.contains { $0.repoType == "templates" && $0.url == HomeCatalogOrigin.githubTemplatesURL })
    }

    @Test func `existing GitHub built-in rows flip on member seed`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        try Seeder.seedDefaultRepository(db: pool, isMember: false)
        try Seeder.seedDefaultRepository(db: pool, isMember: true)
        let repos = try pool.read { try ImageRepository.fetchAll($0) }
        #expect(repos.count == 2)
        #expect(repos.allSatisfy { HomeCatalogOrigin.isMemberOrigin($0.url) })
        #expect(!repos.contains { HomeCatalogOrigin.isGitHubBuiltIn($0.url) })
    }

    @Test func `member sync applies last-good and never fetches GitHub`() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        let repoId = try await insertRepo(
            pool, url: HomeCatalogOrigin.githubTemplatesURL, repoType: "templates",
        )
        let lastGood = LastGoodCatalogStore(directory: dir)
        try lastGood.save(repoType: "templates", data: templatesJSON())
        let fetcher = RecordingCatalogFetcher(result: .failure(
            BarkVisorError.repositorySyncFailed("network"),
        ))
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: lastGood,
            fetcher: fetcher,
            memberCatalogFetchDisabled: true,
        )
        try await service.sync(repositoryID: repoId)
        #expect(await fetcher.urls.isEmpty)
        let count = try await pool.read { db in
            try VMTemplate.filter(Column("slug") == "ok-box").fetchCount(db)
        }
        #expect(count == 1)
    }

    @Test func `member without last-good does not fall back to GitHub`() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        let repoId = try await insertRepo(
            pool, url: HomeCatalogOrigin.githubTemplatesURL, repoType: "templates",
        )
        let fetcher = RecordingCatalogFetcher(result: .success(templatesJSON()))
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: LastGoodCatalogStore(directory: dir),
            fetcher: fetcher,
            memberCatalogFetchDisabled: true,
        )
        await #expect(throws: (any Error).self) {
            try await service.sync(repositoryID: repoId)
        }
        #expect(await fetcher.urls.isEmpty)
        let count = try await pool.read { db in try VMTemplate.fetchCount(db) }
        #expect(count == 0)
    }

    @Test func `home remote sync uses fetcher then publishes verbatim bytes`() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        let repoId = try await insertRepo(
            pool, url: HomeCatalogOrigin.githubTemplatesURL, repoType: "templates",
        )
        let raw = templatesJSON()
        let fetcher = RecordingCatalogFetcher(result: .success(raw))
        let published = PublishedCatalog()
        let lastGood = LastGoodCatalogStore(directory: dir)
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: lastGood,
            fetcher: fetcher,
            memberCatalogFetchDisabled: false,
            publish: { repoType, data in
                await published.record(repoType: repoType, data: data)
            },
        )
        try await service.sync(repositoryID: repoId)
        #expect(await fetcher.urls == [HomeCatalogOrigin.githubTemplatesURL])
        #expect(await published.repoType == "templates")
        #expect(await published.data == raw)
        #expect(lastGood.load(repoType: "templates") == raw)
    }

    @Test func `applied catalog bytes upsert without a remote fetch`() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try pool(in: dir)
        _ = try await insertRepo(pool, url: HomeCatalogOrigin.memberImagesURL, repoType: "images")
        let fetcher = RecordingCatalogFetcher(result: .failure(
            BarkVisorError.repositorySyncFailed("network"),
        ))
        let lastGood = LastGoodCatalogStore(directory: dir)
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: lastGood,
            fetcher: fetcher,
            memberCatalogFetchDisabled: true,
        )
        let raw = imagesJSON()
        try await service.applyCatalogBytes(raw, repoType: "images")
        #expect(await fetcher.urls.isEmpty)
        #expect(lastGood.load(repoType: "images") == raw)
        let slug = try await pool.read { db in
            try RepositoryImage.filter(Column("slug") == "ubuntu-24.04-arm64").fetchOne(db)?.slug
        }
        #expect(slug == "ubuntu-24.04-arm64")
    }

    @Test func `home catalog plane publishes to member agent path`() async {
        let sent = SentCatalog()
        let members = [
            HomeDevice(hostId: "home", role: "self", agentPort: 7_778),
            HomeDevice(hostId: "box", role: "member", agentHost: "10.0.0.8", agentPort: 7_778),
        ]
        let raw = templatesJSON()
        await HomeCatalogPlane.publish(
            repoType: "templates",
            data: raw,
            members: members,
            send: { url, data in
                await sent.record(url: url, data: data)
            },
        )
        #expect(await sent.url?.path == "/api/catalogs/applied/templates")
        #expect(await sent.url?.host == "10.0.0.8")
        #expect(await sent.data == raw)
    }

    @Test func `member pull stores last-good from the home agent plane`() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lastGood = LastGoodCatalogStore(directory: dir)
        let raw = templatesJSON()
        await HomeCatalogPlane.pull(
            repoTypes: ["templates"],
            peers: [
                HomeDevice(hostId: "box", role: "self", agentPort: 7_778),
                HomeDevice(hostId: "home", role: "member", agentHost: "192.168.1.2", agentPort: 7_778),
            ],
            lastGood: lastGood,
            get: { url in
                #expect(url.path == "/api/catalogs/applied/templates")
                return raw
            },
        )
        #expect(lastGood.load(repoType: "templates") == raw)
    }

    @Test func `applied path parsing`() {
        #expect(HomeCatalogPlane.repoType(path: "/api/catalogs/applied/images") == "images")
        #expect(HomeCatalogPlane.repoType(path: "/api/catalogs/applied/templates") == "templates")
        #expect(HomeCatalogPlane.repoType(path: "/api/catalogs/applied/other") == nil)
        #expect(HomeCatalogPlane.repoType(path: "/api/repositories") == nil)
    }

    @Test func `SSRF fetcher rejects a private catalog URL`() async throws {
        let url = try #require(URL(string: "http://192.168.1.10/templates.json"))
        await #expect(throws: (any Error).self) {
            _ = try await SSRFCatalogURLFetcher().fetch(url: url)
        }
    }

    @Test func `shouldFetchRemote keeps custom http repos on members`() {
        #expect(
            HomeCatalogOrigin.shouldFetchRemote(
                url: "https://example.com/custom.json",
                memberCatalogFetchDisabled: true,
            ),
        )
        #expect(
            !HomeCatalogOrigin.shouldFetchRemote(
                url: HomeCatalogOrigin.githubImagesURL,
                memberCatalogFetchDisabled: true,
            ),
        )
        #expect(
            HomeCatalogOrigin.shouldFetchRemote(
                url: HomeCatalogOrigin.githubImagesURL,
                memberCatalogFetchDisabled: false,
            ),
        )
    }
}

private actor RecordingCatalogFetcher: CatalogURLFetching {
    private var recorded: [String] = []
    private let result: Result<Data, Error>

    init(result: Result<Data, Error>) {
        self.result = result
    }

    var urls: [String] {
        recorded
    }

    func fetch(url: URL) async throws -> Data {
        recorded.append(url.absoluteString)
        return try result.get()
    }
}

private actor PublishedCatalog {
    var repoType: String?
    var data: Data?

    func record(repoType: String, data: Data) {
        self.repoType = repoType
        self.data = data
    }
}

private actor SentCatalog {
    var url: URL?
    var data: Data?

    func record(url: URL, data: Data) {
        self.url = url
        self.data = data
    }
}
