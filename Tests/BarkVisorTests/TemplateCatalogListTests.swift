import Foundation
import GRDB
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

@Suite(.serialized)
struct TemplateCatalogListTests {
    @Test func `cached docker read skips a live probe`() {
        let cache = DockerDiscoveryCache()
        let identity = DockerRuntimeIdentity(
            executablePath: "/usr/bin/docker",
            executableStamp: nil,
            contextName: "default",
            endpoint: "unix:///var/run/docker.sock",
            socketPath: nil,
            socketStamp: nil,
        )
        let warm = DockerEngineSnapshot(os: "Linux", composeOK: true, composePlugin: true)
        let makes = MakeCount()
        _ = cache.resolve(identity: identity) {
            makes.bump()
            return warm
        }
        #expect(cache.cachedSnapshot() == warm)
        #expect(makes.count == 1)
        let parked = ParkedRefresh()
        cache.scheduleRefresh = { parked.add($0) }
        cache.refreshOffRequest(detectIdentity: { identity }, make: {
            makes.bump()
            return warm
        })
        #expect(parked.isEmpty)
        #expect(makes.count == 1)
        cache.invalidate()
        #expect(cache.cachedSnapshot() == nil)
        cache.refreshOffRequest(detectIdentity: { identity }, make: {
            makes.bump()
            return warm
        })
        #expect(parked.count == 1)
        #expect(makes.count == 1)
        let coldHost = HostInventoryService.templateCatalogHost(
            hostId: "catalog-host", dockerCache: cache,
        )
        #expect(coldHost.resources.memoryTotalMB == PlatformHost.physicalMemoryMB)
        #expect(coldHost.platform.arch == PlatformCapabilities.hostArch)
        #expect(!coldHost.virtualization.features.dockerEngine)
        #expect(makes.count == 1)
    }

    @Test func `template list skips live docker probe`() async throws {
        let shared = DockerDiscoveryCache.shared
        let previousSchedule = shared.scheduleRefresh
        let sharedParked = ParkedRefresh()
        shared.scheduleRefresh = { sharedParked.add($0) }
        shared.invalidate()
        defer {
            shared.cancelPendingRefresh()
            shared.scheduleRefresh = previousSchedule
            shared.invalidate()
        }

        let harness = try await TemplateListHarness.make()
        do {
            let guardProbe = LiveSnapshotGuard(
                replacement: DockerEngineSnapshot(os: PlatformHost.platformName),
            )
            let listed = try await DockerEngine.$liveSnapshotGuard.withValue(guardProbe) {
                let rows = try await harness.controller.list(req: harness.listRequest())
                var parameters = harness.getRequest().parameters
                parameters.set("id", to: harness.debianId)
                let getRequest = harness.getRequest()
                getRequest.parameters = parameters
                let one = try await harness.controller.get(req: getRequest)
                return (rows, one)
            }
            #expect(guardProbe.callCount == 0)
            #expect(sharedParked.count == 1)

            let debian = try #require(listed.0.first { $0.slug == "debian-13-cloud" })
            #expect(debian.name == "Debian 13")
            #expect(Set(debian.catalogImages.map(\TemplateCatalogImageRef.arch)) == ["arm64", "x86_64"])
            #expect(Set(debian.catalogImages.map(\TemplateCatalogImageRef.slug)) == ["debian-13-arm64", "debian-13-x86_64"])
            let hostArch = PlatformCapabilities.normalizedArch(PlatformCapabilities.hostArch)
            let hostSlug = hostArch == "x86_64" ? "debian-13-x86_64" : "debian-13-arm64"
            #expect(debian.resolvedImageSlug == hostSlug)
            #expect(debian.compatible)
            #expect(listed.1.slug == debian.slug)
            #expect(listed.1.resolvedImageSlug == hostSlug)
            #expect(Set(listed.1.catalogImages.map(\TemplateCatalogImageRef.arch)) == ["arm64", "x86_64"])
            #expect(listed.1.compatible)

            let huge = try #require(listed.0.first { $0.slug == "huge-memory" })
            #expect(huge.resolvedImageSlug == hostSlug)
            #expect(!huge.compatible)
            let needsDocker = try #require(listed.0.first { $0.slug == "needs-docker" })
            #expect(needsDocker.resolvedImageSlug == hostSlug)
            #expect(!needsDocker.compatible)
            try await harness.app.asyncShutdown()
        } catch {
            try? await harness.app.asyncShutdown()
            throw error
        }
    }

    @Test func `deploy rejects missing docker engine`() async throws {
        let shared = DockerDiscoveryCache.shared
        let identity = DockerRuntimeIdentity.detectFromEnvironment()
        _ = shared.resolve(identity: identity) {
            DockerEngineSnapshot(
                os: PlatformHost.platformName, composeOK: true, composePlugin: true,
            )
        }
        let previousProvider = DockerEngine.snapshotProvider
        DockerEngine.snapshotProvider = {
            DockerEngineSnapshot(os: PlatformHost.platformName, composeOK: false)
        }
        defer {
            DockerEngine.snapshotProvider = previousProvider
            shared.invalidate()
        }

        let harness = try await TemplateListHarness.make()
        do {
            var parameters = harness.getRequest().parameters
            parameters.set("id", to: harness.dockerId)
            let dryRunRequest = harness.getRequest()
            dryRunRequest.parameters = parameters
            let report = try await harness.controller.dryRun(req: dryRunRequest)
            #expect(!report.compatible)
            #expect(report.missingFeatures == ["dockerEngine"])
            #expect(report.reasons.contains { $0.code == "feature_missing" })

            do {
                _ = try await TemplateDeployService.deploy(
                    options: DeployOptions(
                        templateId: harness.dockerId, vmName: "needs-docker-vm", inputs: [:],
                    ),
                    imageDownloader: harness.downloader,
                    backgroundTasks: harness.tasks,
                    db: harness.database.pool,
                )
                Issue.record("deploy accepted a host without dockerEngine")
            } catch let BarkVisorError.badRequest(message) {
                #expect(message.contains("dockerEngine"))
            }
            try await harness.app.asyncShutdown()
        } catch {
            try? await harness.app.asyncShutdown()
            throw error
        }
    }
}

private final class MakeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ParkedRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []

    func add(_ item: @escaping @Sendable () -> Void) {
        lock.lock()
        work.append(item)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return work.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return work.isEmpty
    }
}

private struct TemplateListHarness {
    let app: Application
    let database: AppDatabase
    let controller: TemplateController
    let downloader: ImageDownloader
    let tasks: BackgroundTaskManager
    let debianId: String
    let dockerId: String

    static func make() async throws -> TemplateListHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try AppDatabase(path: root.appendingPathComponent("test.sqlite").path)
        try database.migrate()
        let now = iso8601.string(from: Date())
        let repoId = UUID().uuidString
        let debianId = UUID().uuidString
        let dockerId = UUID().uuidString
        let hugeId = UUID().uuidString
        let hostArch = PlatformCapabilities.normalizedArch(PlatformCapabilities.hostArch)
        let hostSlug = hostArch == "x86_64" ? "debian-13-x86_64" : "debian-13-arm64"
        try await database.pool.write { db in
            try ImageRepository(
                id: repoId, name: "catalog", url: "https://example.com/catalog.json",
                isBuiltIn: false, repoType: "templates", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try RepositoryImage(
                id: UUID().uuidString, repositoryId: repoId, slug: "debian-13-arm64",
                name: "Debian 13 arm64", description: nil, imageType: "cloud", arch: "arm64",
                version: "13", downloadUrl: "https://example.com/debian-13-arm64.qcow2",
                sizeBytes: 1_024,
            ).insert(db)
            try RepositoryImage(
                id: UUID().uuidString, repositoryId: repoId, slug: "debian-13-x86_64",
                name: "Debian 13 x86_64", description: nil, imageType: "cloud", arch: "x86_64",
                version: "13", downloadUrl: "https://example.com/debian-13-x86_64.qcow2",
                sizeBytes: 1_024,
            ).insert(db)
            try templateRow(
                CatalogTemplate(
                    id: debianId, slug: "debian-13-cloud", name: "Debian 13",
                    memoryMB: 2_048, minMemoryMB: 512,
                ),
                repoId: repoId, imageSlug: hostSlug, now: now,
            ).insert(db)
            try templateRow(
                CatalogTemplate(
                    id: dockerId, slug: "needs-docker", name: "Needs Docker",
                    memoryMB: 512, required: #"["dockerEngine"]"#,
                ),
                repoId: repoId, imageSlug: hostSlug, now: now,
            ).insert(db)
            try templateRow(
                CatalogTemplate(
                    id: hugeId, slug: "huge-memory", name: "Huge",
                    memoryMB: PlatformHost.physicalMemoryMB + 1,
                    minMemoryMB: PlatformHost.physicalMemoryMB + 1,
                ),
                repoId: repoId, imageSlug: hostSlug, now: now,
            ).insert(db)
        }
        let app = try await Application.make(.testing)
        app.database = database
        let downloader = ImageDownloader(dbPool: { database.pool })
        let tasks = BackgroundTaskManager()
        let controller = TemplateController(
            vmManager: VMManager(dbPool: database.pool),
            imageDownloader: downloader,
            backgroundTasks: tasks,
            syncService: RepositorySyncService(dbPool: database.pool),
        )
        return TemplateListHarness(
            app: app,
            database: database,
            controller: controller,
            downloader: downloader,
            tasks: tasks,
            debianId: debianId,
            dockerId: dockerId,
        )
    }

    func listRequest() -> Request {
        Request(application: app, method: .GET, url: "/api/templates", on: app.eventLoopGroup.any())
    }

    func getRequest() -> Request {
        Request(application: app, method: .GET, url: "/api/templates/id", on: app.eventLoopGroup.any())
    }
}

private struct CatalogTemplate {
    var id: String
    var slug: String
    var name: String
    var memoryMB: Int
    var minMemoryMB: Int?
    var required: String?
}

private func templateRow(
    _ template: CatalogTemplate,
    repoId: String,
    imageSlug: String,
    now: String,
) -> VMTemplate {
    VMTemplate(
        id: template.id, slug: template.slug, name: template.name, description: nil,
        category: "general", icon: "terminal", imageSlug: imageSlug,
        cpuCount: 1, memoryMB: template.memoryMB, diskSizeGB: 8, portForwards: "[]",
        networkMode: "nat", inputs: "[]", userDataTemplate: "",
        isBuiltIn: false, repositoryId: repoId, createdAt: now, updatedAt: now,
        architecturesJson: #"["arm64","x86_64"]"#,
        minMemoryMB: template.minMemoryMB,
        requiredFeaturesJson: template.required,
        imageByArchJson: #"{"arm64":"debian-13-arm64","x86_64":"debian-13-x86_64"}"#,
    )
}
