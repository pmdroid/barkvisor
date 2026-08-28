import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct TemplateDeployDiskSpaceTests {
    @Test func `recipe deploy errors the VM when sizeBytes exceeds Library space`() async throws {
        let (pool, tmp) = try makeDiskSpaceDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/huge-\(host).qcow2"
        let downloader = DiskSpaceStubDownloader()
        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: "tpl",
                    vmName: "huge-recipe",
                    inputs: [:],
                    recipe: diskSpaceRecipe(
                        arch: host, url: url, sizeBytes: 1_000_000_000_000_000,
                    ),
                ),
                imageDownloader: downloader,
                backgroundTasks: BackgroundTaskManager(),
                db: pool,
            )
            Issue.record("expected Library space error")
        } catch let BarkVisorError.insufficientDeviceDiskSpace(deviceName, shortfallBytes) {
            #expect(deviceName == HostInventoryService.snapshot().displayName)
            #expect(shortfallBytes > 0)
        }
        #expect(await downloader.startedURLs.isEmpty)
        let vm = try await pool.read { db in
            try VM.filter(Column("name") == "huge-recipe").fetchOne(db)
        }
        #expect(vm?.state == "error")
        let description = vm?.description ?? ""
        #expect(description.contains("Not enough disk space on this Device"))
        #expect(description.contains(HostInventoryService.snapshot().displayName))
        let pending = try await pool.read { db in try PendingDeploy.fetchCount(db) }
        #expect(pending == 0)
    }

    @Test func `recipe deploy starts download when sizeBytes is unknown`() async throws {
        let (pool, tmp) = try makeDiskSpaceDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/unknown-\(host).qcow2"
        let downloader = DiskSpaceStubDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "unknown-recipe",
                inputs: [:],
                recipe: diskSpaceRecipe(arch: host, url: url, sizeBytes: nil),
            ),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
        )
        guard case let .downloading(_, vm) = result else {
            Issue.record("expected downloading, got \(result)")
            return
        }
        #expect(vm.state == "provisioning")
        #expect(await downloader.startedURLs.contains { $0.absoluteString == url })
    }

    @Test func `recipe deploy starts download when sizeBytes fits`() async throws {
        let (pool, tmp) = try makeDiskSpaceDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/fits-\(host).qcow2"
        let downloader = DiskSpaceStubDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "fits-recipe",
                inputs: [:],
                recipe: diskSpaceRecipe(arch: host, url: url, sizeBytes: 1),
            ),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
        )
        guard case let .downloading(_, vm) = result else {
            Issue.record("expected downloading, got \(result)")
            return
        }
        #expect(vm.state == "provisioning")
        #expect(await downloader.startedURLs.contains { $0.absoluteString == url })
    }

    @Test func `catalog deploy errors the VM when sizeBytes exceeds Library space`() async throws {
        let (pool, tmp) = try makeDiskSpaceDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/catalog-huge-\(host).qcow2"
        let templateId = try await insertCatalogTemplate(
            pool: pool, arch: host, url: url, sizeBytes: 1_000_000_000_000_000,
        )
        let downloader = DiskSpaceStubDownloader()
        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: templateId, vmName: "huge-catalog", inputs: [:],
                ),
                imageDownloader: downloader,
                backgroundTasks: BackgroundTaskManager(),
                db: pool,
            )
            Issue.record("expected Library space error")
        } catch let BarkVisorError.insufficientDeviceDiskSpace(deviceName, shortfallBytes) {
            #expect(deviceName == HostInventoryService.snapshot().displayName)
            #expect(shortfallBytes > 0)
        }
        #expect(await downloader.startedURLs.isEmpty)
        let vm = try await pool.read { db in
            try VM.filter(Column("name") == "huge-catalog").fetchOne(db)
        }
        #expect(vm?.state == "error")
        #expect(vm?.description?.contains("Not enough disk space on this Device") == true)
    }

    @Test func `catalog deploy starts download when sizeBytes fits`() async throws {
        let (pool, tmp) = try makeDiskSpaceDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/catalog-fits-\(host).qcow2"
        let templateId = try await insertCatalogTemplate(
            pool: pool, arch: host, url: url, sizeBytes: 1,
        )
        let downloader = DiskSpaceStubDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: templateId, vmName: "fits-catalog", inputs: [:],
            ),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
        )
        guard case .downloading = result else {
            Issue.record("expected downloading, got \(result)")
            return
        }
        #expect(await downloader.startedURLs.contains { $0.absoluteString == url })
    }
}

private actor DiskSpaceStubDownloader: ImageDownloadStarting {
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

private func diskSpaceRecipe(arch: String, url: String, sizeBytes: Int64?) -> DeployRecipe {
    DeployRecipe(
        name: "Cloud",
        slug: "cloud",
        inputs: [],
        userDataTemplate: "lock_passwd: true",
        cpuCount: 1,
        memoryMB: 512,
        diskSizeGB: 16,
        architectures: [arch],
        image: DeployRecipeImage(
            downloadUrl: url,
            arch: arch,
            imageType: "cloud-image",
            sha256: "aaaaaaaa",
            slug: "cloud-\(arch)",
            sizeBytes: sizeBytes,
        ),
    )
}

private func insertCatalogTemplate(
    pool: DatabasePool,
    arch: String,
    url: String,
    sizeBytes: Int64?,
) async throws -> String {
    let now = iso8601.string(from: Date())
    let repoId = UUID().uuidString
    let templateId = UUID().uuidString
    let slug = "cloud-\(arch)"
    try await pool.write { db in
        try ImageRepository(
            id: repoId, name: "test-templates", url: "https://example.com/catalog.json",
            isBuiltIn: false, repoType: "templates", lastSyncedAt: nil, lastError: nil,
            syncStatus: "idle", createdAt: now, updatedAt: now,
        ).insert(db)
        try RepositoryImage(
            id: UUID().uuidString, repositoryId: repoId, slug: slug,
            name: "Host Cloud", description: nil, imageType: "cloud-image", arch: arch,
            version: "1", downloadUrl: url, sizeBytes: sizeBytes,
        ).insert(db)
        try VMTemplate(
            id: templateId, slug: "multi", name: "Multi", description: nil,
            category: "general", icon: "terminal", imageSlug: slug,
            cpuCount: 1, memoryMB: 512, diskSizeGB: 8, portForwards: "[]",
            networkMode: "nat", inputs: "[]", userDataTemplate: "",
            isBuiltIn: false, repositoryId: repoId, createdAt: now, updatedAt: now,
            architecturesJson: JSONColumnCoding.encode([arch]),
            imageByArchJson: JSONColumnCoding.encode([arch: slug]),
        ).insert(db)
    }
    return templateId
}

private func makeDiskSpaceDB() throws -> (DatabasePool, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    let library = tmp.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try pool.write { db in
        try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
            .save(db, onConflict: .replace)
    }
    return (pool, tmp)
}
