import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct AppCatalogSyncTests {
    private func pool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return (pool, dir)
    }

    @Test func `sync writes catalog rows and leaves application compose alone`() async throws {
        let (pool, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = iso8601.string(from: Date())
        let repoId = UUID().uuidString
        let originalCompose = "services:\n  whoami:\n    image: traefik/whoami:old\n"
        try await pool.write { db in
            try ImageRepository(
                id: repoId, name: "Apps", url: BigBearAppCatalog.originURL,
                isBuiltIn: true, repoType: "apps", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try VM(
                id: "app-1",
                name: "running-whoami",
                vmType: WorkloadSpec.applicationGuestType,
                state: "running",
                cpuCount: 0,
                memoryMb: 0,
                bootDiskId: nil,
                kind: WorkloadSpec.kindApplication,
                runtime: WorkloadSpec.runtimeDevice,
                composeYaml: originalCompose,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: nil,
                displayResolution: nil,
                additionalDiskIds: nil,
                uefi: false,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
        let first = try BigBearAppCatalog.encodeCatalog(
            AppCatalogDocument(
                name: "Big Bear Universal Apps",
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
        let service = RepositorySyncService(dbPool: pool, lastGood: LastGoodCatalogStore(directory: dir))
        try await service.syncCatalogData(first, repositoryID: repoId)
        let rows = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.slug == "whoami")
        #expect(rows.first?.composeYaml.contains("traefik/whoami:v1") == true)

        let second = try BigBearAppCatalog.encodeCatalog(
            AppCatalogDocument(
                name: "Big Bear Universal Apps",
                apps: [
                    AppCatalogEntryDTO(
                        id: "whoami",
                        name: "Whoami",
                        category: "Apps",
                        arches: ["arm64"],
                        compose: "services:\n  whoami:\n    image: traefik/whoami:v2\n",
                    ),
                ],
            ),
        )
        try await service.syncCatalogData(second, repositoryID: repoId)
        let updated = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(updated.count == 1)
        #expect(updated.first?.composeYaml.contains("traefik/whoami:v2") == true)
        let vm = try await pool.read { db in try VM.fetchOne(db, key: "app-1") }
        #expect(vm?.composeYaml == originalCompose)
    }

    @Test func `empty apps catalog does not wipe existing rows`() async throws {
        let (pool, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = iso8601.string(from: Date())
        let repoId = UUID().uuidString
        try await pool.write { db in
            try ImageRepository(
                id: repoId, name: "Apps", url: BigBearAppCatalog.originURL,
                isBuiltIn: true, repoType: "apps", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let first = try BigBearAppCatalog.encodeCatalog(
            AppCatalogDocument(
                name: "Big Bear Universal Apps",
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
        let service = RepositorySyncService(dbPool: pool, lastGood: LastGoodCatalogStore(directory: dir))
        try await service.syncCatalogData(first, repositoryID: repoId)
        let empty = try BigBearAppCatalog.encodeCatalog(
            AppCatalogDocument(name: "Big Bear Universal Apps", apps: []),
        )
        await #expect(throws: BarkVisorError.self) {
            try await service.syncCatalogData(empty, repositoryID: repoId)
        }
        let rows = try await pool.read { db in try AppCatalogRecord.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.slug == "whoami")
    }

    @Test func `zipball URL is derived from the GitHub repo`() {
        let url = BigBearAppCatalog.zipballURL(from: "https://github.com/bigbeartechworld/big-bear-universal-apps")
        #expect(url?.absoluteString == BigBearAppCatalog.zipballURL)
        #expect(
            BigBearAppCatalog.zipballURL(from: "https://github.com/bigbeartechworld/big-bear-universal-apps.git")?
                .absoluteString == BigBearAppCatalog.zipballURL,
        )
    }
}
