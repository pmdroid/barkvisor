import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct RepositorySyncDecodeTests {
    @Test func `catalog fixture missing TemplateInput field names the field in lastError`()
        async throws {
        let json = """
        {
          "version": 1,
          "templates": [
            {
              "slug": "broken-box",
              "name": "Broken Box",
              "category": "general",
              "icon": "terminal",
              "imageSlug": "ubuntu-24.04-arm64",
              "cpuCount": 1,
              "memoryMB": 512,
              "diskSizeGB": 8,
              "portForwards": [],
              "networkMode": "nat",
              "inputs": [
                {
                  "id": "hostname",
                  "type": "text",
                  "required": true
                }
              ],
              "userDataTemplate": "#cloud-config\\n"
            }
          ]
        }
        """
        let (pool, repoId) = try await makeRepoPool()
        let service = RepositorySyncService(dbPool: pool)
        try await service.syncCatalogData(Data(json.utf8), repositoryID: repoId)

        let repo = try await pool.read { db in
            try ImageRepository.fetchOne(db, key: repoId)
        }
        let lastError = repo?.lastError ?? ""
        #expect(lastError.contains("label"))
        #expect(lastError.contains("broken-box"))
        #expect(lastError.contains("templates"))
        #expect(!lastError.localizedCaseInsensitiveContains("isn't in the correct format"))
        #expect(!lastError.localizedCaseInsensitiveContains("isn’t in the correct format"))

        let templates = try await pool.read { db in
            try VMTemplate.filter(Column("repositoryId") == repoId).fetchAll(db)
        }
        #expect(templates.isEmpty)
    }

    @Test func `mixed catalog skips the bad entry and syncs the rest`() async throws {
        let json = """
        {
          "version": 1,
          "templates": [
            {
              "slug": "ok-box",
              "name": "Ok Box",
              "category": "general",
              "icon": "terminal",
              "imageSlug": "ubuntu-24.04-arm64",
              "cpuCount": 2,
              "memoryMB": 1024,
              "diskSizeGB": 16,
              "portForwards": [],
              "networkMode": "nat",
              "inputs": [
                {
                  "id": "hostname",
                  "label": "Hostname",
                  "type": "text",
                  "required": true
                }
              ],
              "userDataTemplate": "#cloud-config\\n"
            },
            {
              "slug": "broken-box",
              "name": "Broken Box",
              "category": "general",
              "icon": "terminal",
              "imageSlug": "ubuntu-24.04-arm64",
              "cpuCount": 1,
              "memoryMB": 512,
              "diskSizeGB": 8,
              "portForwards": [],
              "networkMode": "nat",
              "inputs": [
                {
                  "id": "hostname",
                  "type": "text",
                  "required": true
                }
              ],
              "userDataTemplate": "#cloud-config\\n"
            },
            {
              "slug": "fedora-box",
              "name": "Fedora Box",
              "category": "general",
              "icon": "terminal",
              "imageSlug": "fedora-44-arm64",
              "cpuCount": 4,
              "memoryMB": 2048,
              "diskSizeGB": 32,
              "portForwards": [],
              "networkMode": "nat",
              "inputs": [
                {
                  "id": "hostname",
                  "label": "Hostname",
                  "type": "text",
                  "required": true
                }
              ],
              "userDataTemplate": "#cloud-config\\n"
            }
          ]
        }
        """
        let (pool, repoId) = try await makeRepoPool()
        let service = RepositorySyncService(dbPool: pool)
        try await service.syncCatalogData(Data(json.utf8), repositoryID: repoId)

        let templates = try await pool.read { db in
            try VMTemplate.filter(Column("repositoryId") == repoId).fetchAll(db)
        }
        let slugs = Set(templates.map(\.slug))
        #expect(slugs == ["ok-box", "fedora-box"])
        #expect(templates.first { $0.slug == "ok-box" }?.memoryMB == 1_024)
        #expect(templates.first { $0.slug == "fedora-box" }?.imageSlug == "fedora-44-arm64")

        let repo = try await pool.read { db in
            try ImageRepository.fetchOne(db, key: repoId)
        }
        let lastError = repo?.lastError ?? ""
        #expect(lastError.contains("broken-box"))
        #expect(lastError.contains("label"))
        #expect(!lastError.contains("ok-box"))
        #expect(!lastError.contains("fedora-box"))
        #expect(repo?.lastSyncedAt != nil)
    }

    @Test func `template catalog without images still syncs`() throws {
        let json = """
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
              "inputs": [
                {
                  "id": "hostname",
                  "label": "Hostname",
                  "type": "text",
                  "required": true
                }
              ],
              "userDataTemplate": "#cloud-config\\n"
            }
          ]
        }
        """
        let decoded = try RepositoryCatalogDecoder.decode(Data(json.utf8), repoName: "local")
        let catalog = decoded.catalog
        #expect(catalog.name == "local")
        #expect(catalog.images.isEmpty)
        #expect(catalog.templates?.count == 1)
        #expect(catalog.templates?.first?.slug == "ok-box")
        #expect(catalog.templates?.first?.inputs.first?.label == "Hostname")
        #expect(decoded.skippedTemplatesMessage == nil)
    }

    @Test func `repo catalog still decodes with images`() throws {
        let json = """
        {
          "name": "Official",
          "version": 1,
          "images": [
            {
              "slug": "alpine-3.24-arm64",
              "name": "Alpine",
              "imageType": "iso",
              "arch": "arm64",
              "downloadUrl": "https://example.com/alpine.iso"
            }
          ]
        }
        """
        let decoded = try RepositoryCatalogDecoder.decode(Data(json.utf8), repoName: "ignored")
        let catalog = decoded.catalog
        #expect(catalog.name == "Official")
        #expect(catalog.images.count == 1)
        #expect(catalog.images[0].slug == "alpine-3.24-arm64")
        #expect(decoded.skippedTemplatesMessage == nil)
    }

    private func makeRepoPool() async throws -> (DatabasePool, String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let repoId = UUID().uuidString
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try ImageRepository(
                id: repoId, name: "test-templates", url: "https://example.com/templates.json",
                isBuiltIn: false, repoType: "templates", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
        }
        return (pool, repoId)
    }
}
