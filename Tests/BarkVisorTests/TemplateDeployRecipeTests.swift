import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct TemplateDeployRecipeTests {
    @Test func `recipe deploy downloads without a local catalog row`() async throws {
        let (pool, tmp) = try makeDeployDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/fedora-\(host).qcow2"
        let downloader = ArchStubImageDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "home-only-id",
                vmName: "fedora-box",
                inputs: [:],
                recipe: hostRecipe(arch: host, url: url, inputs: []),
            ),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
        )
        guard case let .downloading(imageId, vm) = result else {
            Issue.record("expected download from recipe URL, got \(result)")
            return
        }
        #expect(!imageId.isEmpty)
        #expect(vm.state == "provisioning")
        let stored = try await pool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(stored != nil)
        #expect(stored?.bootDiskId.isEmpty == false)
        let started = await downloader.startedURLs
        #expect(started.contains { $0.absoluteString == url })
        let templateCount = try await pool.read { db in try VMTemplate.fetchCount(db) }
        #expect(templateCount == 0)
        let repoCount = try await pool.read { db in try RepositoryImage.fetchCount(db) }
        #expect(repoCount == 0)
    }

    @Test func `recipe enforces required inputs from the payload`() async throws {
        let (pool, tmp) = try makeDeployDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let downloader = ArchStubImageDownloader()
        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: "home-only-id",
                    vmName: "box",
                    inputs: [:],
                    recipe: hostRecipe(
                        arch: host,
                        url: "https://example.com/cloud.qcow2",
                        inputs: [
                            TemplateInput(
                                id: "password", label: "Password", type: "password",
                                default: nil, required: true, placeholder: nil,
                                minLength: nil, maxLength: nil,
                            ),
                        ],
                    ),
                ),
                imageDownloader: downloader,
                backgroundTasks: BackgroundTaskManager(),
                db: pool,
            )
            Issue.record("expected missing required input")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message == "Missing required input: Password")
        }
        #expect(await downloader.startedURLs.isEmpty)
        let vmCount = try await pool.read { db in try VM.fetchCount(db) }
        #expect(vmCount == 0)
    }

    @Test func `recipe enforces min and max input length from the payload`() async throws {
        let (pool, tmp) = try makeDeployDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let recipe = hostRecipe(
            arch: host,
            url: "https://example.com/cloud.qcow2",
            inputs: [
                TemplateInput(
                    id: "password", label: "Password", type: "password",
                    default: nil, required: true, placeholder: nil,
                    minLength: 8, maxLength: 12,
                ),
            ],
        )
        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: "home-only-id",
                    vmName: "box",
                    inputs: ["password": "short"],
                    recipe: recipe,
                ),
                imageDownloader: ArchStubImageDownloader(),
                backgroundTasks: BackgroundTaskManager(),
                db: pool,
            )
            Issue.record("expected min length error")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message == "Password must be at least 8 characters")
        }

        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: "home-only-id",
                    vmName: "box",
                    inputs: ["password": "way-too-long-secret"],
                    recipe: recipe,
                ),
                imageDownloader: ArchStubImageDownloader(),
                backgroundTasks: BackgroundTaskManager(),
                db: pool,
            )
            Issue.record("expected max length error")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message == "Password must be at most 12 characters")
        }
        let vmCount = try await pool.read { db in try VM.fetchCount(db) }
        #expect(vmCount == 0)
    }

    @Test func `recipe rejects foreign arch before download`() async throws {
        let (pool, tmp) = try makeDeployDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let foreign = host == "arm64" ? "x86_64" : "arm64"
        let downloader = ArchStubImageDownloader()
        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: "home-only-id",
                    vmName: "box",
                    inputs: [:],
                    recipe: hostRecipe(
                        arch: foreign,
                        url: "https://example.com/foreign.qcow2",
                        inputs: [],
                    ),
                ),
                imageDownloader: downloader,
                backgroundTasks: BackgroundTaskManager(),
                db: pool,
            )
            Issue.record("expected foreign-arch recipe to fail")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.lowercased().contains("not compatible")
                || message.lowercased().contains("cross-architecture"))
        }
        #expect(await downloader.startedURLs.isEmpty)
        let vmCount = try await pool.read { db in try VM.fetchCount(db) }
        #expect(vmCount == 0)
    }

    @Test func `legacy deploy JSON ignores recipe fields`() throws {
        let json = """
        {
          "templateId": "tpl-1",
          "vmName": "box",
          "inputs": {"username": "ubuntu"},
          "recipe": {
            "name": "Ubuntu Server",
            "slug": "ubuntu-cloud",
            "inputs": [],
            "userDataTemplate": "lock_passwd: true",
            "cpuCount": 2,
            "memoryMB": 2048,
            "diskSizeGB": 16,
            "image": {
              "downloadUrl": "https://example.com/ubuntu.qcow2",
              "arch": "arm64",
              "imageType": "cloud-image",
              "sha256": "abc"
            }
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let legacy = try JSONDecoder().decode(LegacyDeployBody.self, from: data)
        #expect(legacy.templateId == "tpl-1")
        #expect(legacy.vmName == "box")
        #expect(legacy.inputs["username"] == "ubuntu")

        let decoded = try JSONDecoder().decode(DeployTemplateRequest.self, from: data)
        #expect(decoded.recipe?.image.downloadUrl == "https://example.com/ubuntu.qcow2")
        #expect(decoded.recipe?.image.sha256 == "abc")
    }

    @Test func `template response includes catalog image urls`() {
        let template = VMTemplate(
            id: "tpl-1", slug: "ubuntu-cloud", name: "Ubuntu Server", description: nil,
            category: "linux", icon: "ubuntu", imageSlug: "ubuntu-24.04-arm64",
            cpuCount: 2, memoryMB: 2_048, diskSizeGB: 20, portForwards: "[]",
            networkMode: "nat", inputs: "[]", userDataTemplate: "",
            isBuiltIn: true, repositoryId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
        )
        let img = RepositoryImage(
            id: "ri-1", repositoryId: "r1", slug: "ubuntu-24.04-arm64",
            name: "Ubuntu", description: nil, imageType: "cloud-image", arch: "arm64",
            version: "1", downloadUrl: "https://example.com/ubuntu.qcow2", sizeBytes: 1,
            sha256: "deadbeef",
        )
        let response = TemplateResponse(
            from: template, catalogImages: [TemplateCatalogImageRef(from: img)],
        )
        #expect(response.catalogImages.count == 1)
        #expect(response.catalogImages[0].downloadUrl == "https://example.com/ubuntu.qcow2")
        #expect(response.catalogImages[0].sha256 == "deadbeef")
    }
}

private struct LegacyDeployBody: Decodable {
    let templateId: String
    let vmName: String
    let inputs: [String: String]
}

private func hostRecipe(arch: String, url: String, inputs: [TemplateInput]) -> DeployRecipe {
    DeployRecipe(
        name: "Fedora Cloud",
        slug: "fedora-cloud",
        inputs: inputs,
        userDataTemplate: "lock_passwd: true",
        cpuCount: 2,
        memoryMB: 2_048,
        diskSizeGB: 16,
        architectures: [arch],
        image: DeployRecipeImage(
            downloadUrl: url,
            arch: arch,
            imageType: "cloud-image",
            sha256: "aaaaaaaa",
            slug: "fedora-\(arch)",
        ),
    )
}

private func makeDeployDB() throws -> (DatabasePool, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    return (pool, tmp)
}

private actor ArchStubImageDownloader: ImageDownloadStarting {
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
