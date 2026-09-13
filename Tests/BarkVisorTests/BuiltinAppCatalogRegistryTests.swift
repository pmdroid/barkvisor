import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct BuiltinAppCatalogRegistryTests {
    @Test func `parses canonical builtin origins`() {
        #expect(BuiltinAppCatalogRegistry.parseName("barkvisor://builtin/linuxserver") == "linuxserver")
        #expect(BuiltinAppCatalogRegistry.parseName("barkvisor://builtin/bigbear") == "bigbear")
        #expect(BuiltinAppCatalogRegistry.parseName("  barkvisor://builtin/bigbear  ") == "bigbear")
        #expect(BuiltinAppCatalogRegistry.parseName("barkvisor://builtin/big-bear-2") == "big-bear-2")
    }

    @Test func `parser is strict about scheme host and single lowercase segment`() {
        let rejected: [String] = [
            "",
            "bigbear",
            "https://github.com/bigbeartechworld/big-bear-universal-apps",
            "barkvisor://home/catalog/apps",
            "barkvisor://builtin",
            "barkvisor://builtin/",
            "barkvisor://builtin//bigbear",
            "barkvisor://builtin/bigbear/",
            "barkvisor://builtin/bigbear/apps",
            "barkvisor://builtin/BigBear",
            "barkvisor://Builtin/bigbear",
            "barkvisor://BUILTIN/bigbear",
            "BARKVISOR://builtin/bigbear",
            "barkvisor://builtin/big bear",
            "barkvisor://builtin/big_bear",
            "barkvisor://builtin/bigbear?x=1",
            "barkvisor://builtin/bigbear#frag",
            "barkvisor://builtin:8080/bigbear",
            "barkvisor://builtin/-bigbear",
            "barkvisor://builtin/bigbear-",
            "barkvisor://builtin/../bigbear",
        ]
        for url in rejected {
            #expect(
                BuiltinAppCatalogRegistry.parseName(url) == nil,
                "expected reject: \(url)",
            )
        }
    }

    @Test func `resolve maps registered names and rejects unknown ones`() throws {
        let linuxServer = try #require(BuiltinAppCatalogRegistry.resolve("barkvisor://builtin/linuxserver"))
        #expect(linuxServer.name == "linuxserver")
        #expect(linuxServer.displayName == LinuxServerAppCatalog.catalogName)
        #expect(linuxServer.originURL == LinuxServerAppCatalog.originURL)
        if case let .bundled(load) = linuxServer.backing {
            let data = try load()
            #expect(!data.isEmpty)
        } else {
            Issue.record("linuxserver must be a bundled built-in")
        }

        let bigBear = try #require(BuiltinAppCatalogRegistry.resolve("barkvisor://builtin/bigbear"))
        #expect(bigBear.name == "bigbear")
        #expect(bigBear.displayName == BigBearAppCatalog.catalogName)
        #expect(bigBear.originURL == "barkvisor://builtin/bigbear")
        if case let .fetch(zipballURL) = bigBear.backing {
            #expect(zipballURL == BigBearAppCatalog.zipballURL)
        } else {
            Issue.record("bigbear must be a fetch-backed built-in")
        }

        #expect(BuiltinAppCatalogRegistry.resolve("barkvisor://builtin/nosuch") == nil)
        #expect(BuiltinAppCatalogRegistry.isBuiltinOrigin("barkvisor://builtin/nosuch"))
        #expect(!BuiltinAppCatalogRegistry.isBuiltinOrigin("https://example.com/catalog.json"))
    }

    @Test func `controller rejects user-supplied barkvisor URLs with a clear message`() {
        let cases = [
            "barkvisor://builtin/bigbear",
            "barkvisor://builtin/linuxserver",
            "BARKVISOR://builtin/bigbear",
            "  barkvisor://builtin/anything  ",
            "barkvisor://home/catalog/apps",
        ]
        for url in cases {
            let reason = RepositoryController.reservedSchemeRejection(for: url)
            #expect(reason != nil, "expected reject: \(url)")
            #expect(reason?.contains("barkvisor://") == true)
            #expect(reason?.contains("https://") == true)
        }
        #expect(RepositoryController.reservedSchemeRejection(for: "https://example.com/catalog.json") == nil)
        #expect(RepositoryController.reservedSchemeRejection(for: "http://example.com/c.json") == nil)
        #expect(RepositoryController.reservedSchemeRejection(for: "") == nil)
    }
}

struct BuiltinAppCatalogSyncTests {
    private func makeDB() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return (pool, dir)
    }

    private func insertAppsRepo(_ pool: DatabasePool, id: String, url: String) async throws {
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try ImageRepository(
                id: id, name: BigBearAppCatalog.catalogName, url: url,
                isBuiltIn: true, repoType: "apps", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
    }

    private func appsBytes() throws -> Data {
        try BigBearAppCatalog.encodeCatalog(
            AppCatalogDocument(
                name: BigBearAppCatalog.catalogName,
                apps: [
                    AppCatalogEntryDTO(
                        id: "whoami",
                        name: "Whoami",
                        category: "Apps",
                        arches: ["arm64"],
                        compose: "services:\n  whoami:\n    image: traefik/whoami:v1\n",
                    ),
                ],
            ),
        )
    }

    @Test func `big bear builtin URL fetches the registry zipball and applies apps`() async throws {
        let (pool, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await insertAppsRepo(pool, id: "bb", url: BigBearAppCatalog.originURL)
        let fetcher = try BuiltinRecordingFetcher(result: .success(appsBytes()))
        let published = BuiltinPublished()
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
        try await service.sync(repositoryID: "bb")
        #expect(await fetcher.urls == [BigBearAppCatalog.zipballURL])
        let rows = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.slug == "whoami")
        #expect(await published.repoType == "apps")
        #expect(await published.data != nil)
        let persisted = lastGood.load(repoType: "apps")
        #expect(persisted != nil)
        let snapshot = try BigBearAppCatalog.decodeCatalog(persisted ?? Data())
        #expect(snapshot.apps.count == 1)
        #expect(snapshot.apps.first?.id == "whoami")
    }

    @Test func `member with fetch disabled falls back to last-good without touching GitHub`() async throws {
        let (pool, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await insertAppsRepo(pool, id: "bb", url: BigBearAppCatalog.originURL)
        let lastGood = LastGoodCatalogStore(directory: dir)
        try lastGood.save(repoType: "apps", data: appsBytes())
        let fetcher = BuiltinRecordingFetcher(result: .failure(
            BarkVisorError.repositorySyncFailed("network must not be used"),
        ))
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: lastGood,
            fetcher: fetcher,
            memberCatalogFetchDisabled: true,
        )
        try await service.sync(repositoryID: "bb")
        #expect(await fetcher.urls.isEmpty)
        let rows = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(rows.first?.slug == "whoami")
    }

    @Test func `member with fetch disabled and no last-good fails without fetching`() async throws {
        let (pool, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await insertAppsRepo(pool, id: "bb", url: BigBearAppCatalog.originURL)
        let fetcher = BuiltinRecordingFetcher(result: .success(Data()))
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: LastGoodCatalogStore(directory: dir),
            fetcher: fetcher,
            memberCatalogFetchDisabled: true,
        )
        await #expect(throws: (any Error).self) {
            try await service.sync(repositoryID: "bb")
        }
        #expect(await fetcher.urls.isEmpty)
    }

    @Test func `unregistered builtin origin is never fetched`() async throws {
        let (pool, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await insertAppsRepo(pool, id: "rogue", url: "barkvisor://builtin/rogue")
        let fetcher = BuiltinRecordingFetcher(result: .success(Data()))
        let service = RepositorySyncService(
            dbPool: pool,
            lastGood: LastGoodCatalogStore(directory: dir),
            fetcher: fetcher,
            memberCatalogFetchDisabled: false,
        )
        await #expect(throws: (any Error).self) {
            try await service.sync(repositoryID: "rogue")
        }
        #expect(await fetcher.urls.isEmpty)
    }

    @Test func `bundled linuxserver resolves through the registry without HTTP`() async throws {
        let (pool, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await insertAppsRepo(pool, id: "ls", url: LinuxServerAppCatalog.originURL)
        let fetcher = BuiltinRecordingFetcher(result: .failure(
            BarkVisorError.repositorySyncFailed("should not fetch"),
        ))
        let service = RepositorySyncService(dbPool: pool, fetcher: fetcher)
        try await service.sync(repositoryID: "ls")
        #expect(await fetcher.urls.isEmpty)
        let rows = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(rows.contains { $0.slug == "jellyfin" && $0.source == "linuxserver" })
    }
}

private actor BuiltinRecordingFetcher: CatalogURLFetching {
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

private actor BuiltinPublished {
    var repoType: String?
    var data: Data?

    func record(repoType: String, data: Data) {
        self.repoType = repoType
        self.data = data
    }
}
