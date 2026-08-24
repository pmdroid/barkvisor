import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct TemplateArchitectureTests {
    @Test func `declared architectures prefer explicit list`() {
        let arches = TemplateArchitecture.declaredArchitectures(
            explicit: ["aarch64", "amd64"],
            imageByArch: ["x86_64": "ubuntu-24.04-x86_64"],
            imageSlug: "ubuntu-24.04-arm64",
        )
        #expect(arches == ["arm64", "x86_64"])
    }

    @Test func `declared architectures fall back to imageByArch then slug`() {
        let fromMap = TemplateArchitecture.declaredArchitectures(
            explicit: [],
            imageByArch: ["x86_64": "ubuntu-24.04-x86_64"],
            imageSlug: "ubuntu-24.04-arm64",
        )
        #expect(fromMap == ["x86_64"])

        let fromSlug = TemplateArchitecture.declaredArchitectures(
            explicit: [],
            imageByArch: [:],
            imageSlug: "ubuntu-24.04-arm64",
        )
        #expect(fromSlug == ["arm64"])
    }

    @Test func `resolveImageSlug uses per-arch map`() {
        let slug = TemplateArchitecture.resolveImageSlug(
            defaultSlug: "ubuntu-24.04-arm64",
            imageByArch: [
                "arm64": "ubuntu-24.04-arm64",
                "x86_64": "ubuntu-24.04-x86_64",
            ],
            arch: "amd64",
        )
        #expect(slug == "ubuntu-24.04-x86_64")
    }

    @Test func `resolveImageSlug returns nil for unsupported arch`() {
        let slug = TemplateArchitecture.resolveImageSlug(
            defaultSlug: "ubuntu-24.04-arm64",
            imageByArch: ["arm64": "ubuntu-24.04-arm64"],
            arch: "x86_64",
        )
        #expect(slug == nil)
    }

    @Test func `legacy slug-only template resolves matching host only`() {
        #expect(
            TemplateArchitecture.resolveImageSlug(
                defaultSlug: "ubuntu-24.04-arm64",
                imageByArch: [:],
                arch: "arm64",
            ) == "ubuntu-24.04-arm64",
        )
        #expect(
            TemplateArchitecture.resolveImageSlug(
                defaultSlug: "ubuntu-24.04-arm64",
                imageByArch: [:],
                arch: "x86_64",
            ) == nil,
        )
    }

    @Test func `compatibility blocks wrong arch`() {
        let template = VMTemplate(
            id: "t1", slug: "pi-hole", name: "Pi-hole", description: nil,
            category: "networking", icon: "shield",
            imageSlug: "ubuntu-24.04-arm64", cpuCount: 1, memoryMB: 512, diskSizeGB: 8,
            portForwards: "[]", networkMode: "bridged", inputs: "[]",
            userDataTemplate: "", isBuiltIn: true, repositoryId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            architecturesJson: #"["arm64"]"#,
            imageByArchJson: #"{"arm64":"ubuntu-24.04-arm64"}"#,
        )
        let host = makeTemplateHost(arch: "x86_64", bridged: true)
        let report = TemplateCompatibility.evaluate(template: template, host: host)
        #expect(!report.compatible)
        #expect(report.reasons.contains { $0.code == "arch_unsupported" })
        #expect(report.resolvedImageSlug == nil)
    }

    @Test func `compatibility resolves multi-arch and reports missing features`() {
        let template = VMTemplate(
            id: "t1", slug: "pi-hole", name: "Pi-hole", description: nil,
            category: "networking", icon: "shield",
            imageSlug: "ubuntu-24.04-arm64", cpuCount: 1, memoryMB: 512, diskSizeGB: 8,
            portForwards: "[]", networkMode: "bridged", inputs: "[]",
            userDataTemplate: "", isBuiltIn: true, repositoryId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            architecturesJson: #"["arm64","x86_64"]"#,
            minMemoryMB: 512,
            requiredFeaturesJson: #"["bridgedNetworking"]"#,
            imageByArchJson: #"{"arm64":"ubuntu-24.04-arm64","x86_64":"ubuntu-24.04-x86_64"}"#,
        )
        let ok = TemplateCompatibility.evaluate(
            template: template, host: makeTemplateHost(arch: "x86_64", bridged: true),
        )
        #expect(ok.compatible)
        #expect(ok.resolvedImageSlug == "ubuntu-24.04-x86_64")

        let missing = TemplateCompatibility.evaluate(
            template: template, host: makeTemplateHost(arch: "x86_64", bridged: false),
        )
        #expect(!missing.compatible)
        #expect(missing.missingFeatures == ["bridgedNetworking"])
        #expect(missing.reasons.contains { $0.code == "feature_missing" })
    }

    @Test func `compatibility honors requested memory override`() {
        let template = VMTemplate(
            id: "t1", slug: "ubuntu-cloud", name: "Ubuntu Cloud", description: nil,
            category: "linux", icon: "ubuntu",
            imageSlug: "ubuntu-24.04-x86_64", cpuCount: 2, memoryMB: 2_048, diskSizeGB: 20,
            portForwards: "[]", networkMode: "nat", inputs: "[]",
            userDataTemplate: "", isBuiltIn: true, repositoryId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            architecturesJson: #"["x86_64"]"#,
            minMemoryMB: 512,
            imageByArchJson: #"{"x86_64":"ubuntu-24.04-x86_64"}"#,
        )
        let host = makeTemplateHost(arch: "x86_64", bridged: false)
        let ok = TemplateCompatibility.evaluate(template: template, host: host)
        #expect(ok.compatible)

        let low = TemplateCompatibility.evaluate(
            template: template, host: host, requestedMemoryMB: 128,
        )
        #expect(!low.compatible)
        #expect(low.reasons.contains { $0.code == "min_memory" })
    }

    @Test func `deploy resolves host-arch image slug`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)

        let host = PlatformCapabilities.hostArch
        let foreign = host == "arm64" ? "x86_64" : "arm64"
        let now = iso8601.string(from: Date())
        let repoId = UUID().uuidString
        let templateId = UUID().uuidString
        let hostSlug = "cloud-\(host)"
        let foreignSlug = "cloud-\(foreign)"

        try await pool.write { db in
            try ImageRepository(
                id: repoId, name: "test-templates", url: "https://example.com/catalog.json",
                isBuiltIn: false, repoType: "templates", lastSyncedAt: nil, lastError: nil,
                syncStatus: "idle", createdAt: now, updatedAt: now,
            ).insert(db)
            try RepositoryImage(
                id: UUID().uuidString, repositoryId: repoId, slug: hostSlug,
                name: "Host Cloud", description: nil, imageType: "cloud", arch: host,
                version: "1", downloadUrl: "https://example.com/\(hostSlug).qcow2", sizeBytes: 1_024,
            ).insert(db)
            try RepositoryImage(
                id: UUID().uuidString, repositoryId: repoId, slug: foreignSlug,
                name: "Foreign Cloud", description: nil, imageType: "cloud", arch: foreign,
                version: "1", downloadUrl: "https://example.com/\(foreignSlug).qcow2", sizeBytes: 1_024,
            ).insert(db)
            try VMTemplate(
                id: templateId, slug: "multi", name: "Multi", description: nil,
                category: "general", icon: "terminal", imageSlug: foreignSlug,
                cpuCount: 1, memoryMB: 512, diskSizeGB: 8, portForwards: "[]",
                networkMode: "nat", inputs: "[]", userDataTemplate: "",
                isBuiltIn: false, repositoryId: repoId, createdAt: now, updatedAt: now,
                architecturesJson: #"["arm64","x86_64"]"#,
                imageByArchJson: #"{"arm64":"cloud-arm64","x86_64":"cloud-x86_64"}"#,
            ).insert(db)
        }

        let downloader = ArchStubImageDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(templateId: templateId, vmName: "multi-arch", inputs: [:]),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
        )
        guard case .downloading = result else {
            Issue.record("expected download of host-arch image, got \(result)")
            return
        }

        let started = await downloader.startedURLs
        #expect(started.contains { $0.absoluteString.contains(hostSlug) })
        #expect(!started.contains { $0.absoluteString.contains(foreignSlug) })
    }

    @Test func `unknown hostId is rejected`() throws {
        let host = makeTemplateHost(arch: "arm64", bridged: true)
        try TemplateCompatibility.requireLocalHost(requestedHostId: nil, inventory: host)
        try TemplateCompatibility.requireLocalHost(requestedHostId: host.hostId, inventory: host)
        #expect(throws: BarkVisorError.self) {
            try TemplateCompatibility.requireLocalHost(
                requestedHostId: "other-host", inventory: host,
            )
        }
    }
}

struct CatalogSlugResolutionTests {
    @Test func `every template image slug resolves in images catalog`() throws {
        let root = repoRoot()
        let templatesURL = root.appendingPathComponent("repos/templates.json")
        let imagesURL = root.appendingPathComponent("repos/images.json")
        let templatesData = try Data(contentsOf: templatesURL)
        let imagesData = try Data(contentsOf: imagesURL)

        let catalog = try JSONDecoder().decode(TemplateCatalog.self, from: templatesData)
        let images = try JSONDecoder().decode(RepoCatalog.self, from: imagesData)
        let slugs = Set(images.images.map(\.slug))
        #expect(!catalog.templates.isEmpty)

        var missing: [String] = []
        for entry in catalog.templates {
            var needed = [entry.imageSlug]
            needed.append(contentsOf: Array(entry.imageByArch?.values ?? [:].values))
            for slug in Set(needed) where !slugs.contains(slug) {
                missing.append("\(entry.slug) → \(slug)")
            }
        }
        #expect(missing.isEmpty, "Unresolved template image slugs: \(missing.joined(separator: ", "))")
    }

    @Test func `onyx template is ubuntu cloud-init with lite compose`() throws {
        let url = repoRoot().appendingPathComponent("repos/templates.json")
        let catalog = try JSONDecoder().decode(TemplateCatalog.self, from: Data(contentsOf: url))
        let row = try #require(catalog.templates.first { $0.slug == "onyx" })
        #expect(row.name == "Onyx")
        #expect(row.networkMode == "nat")
        #expect(row.imageByArch?["arm64"] == "ubuntu-24.04-arm64")
        #expect(row.imageByArch?["x86_64"] == "ubuntu-24.04-x86_64")
        #expect(row.portForwards.contains { $0.protocol == "tcp" && $0.guestPort == 80 })
        #expect(row.userDataTemplate.contains("docker-compose.onyx-lite.yml"))
        #expect(row.userDataTemplate.contains("http://10.0.2.2:11434"))
        #expect(!row.userDataTemplate.contains("10.0.2.2:11434/v1"))
        #expect(!row.userDataTemplate.contains(":7777"))
    }

    @Test func `checksum pins do not use rotating catalog URLs`() throws {
        let imagesURL = repoRoot().appendingPathComponent("repos/images.json")
        let images = try JSONDecoder().decode(RepoCatalog.self, from: Data(contentsOf: imagesURL))
        #expect(!images.images.isEmpty)

        var rotating: [String] = []
        for image in images.images {
            let hasPin = !(image.sha256 ?? "").isEmpty || !(image.sha512 ?? "").isEmpty
            guard hasPin else { continue }
            let url = image.downloadUrl
            if url.contains("/current/") || url.contains("/latest/") || url.contains(".latest.") {
                rotating.append("\(image.slug) → \(url)")
            }
        }
        #expect(
            rotating.isEmpty,
            "Checksum pins must use dated snapshot URLs, not rotating aliases: \(rotating.joined(separator: ", "))",
        )
    }

    @Test func `bundled server templates.json is gone`() {
        let bundled = repoRoot()
            .appendingPathComponent("Sources/BarkVisor/Server/Resources/templates.json")
        #expect(!FileManager.default.fileExists(atPath: bundled.path))
    }
}

private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
    }
    Issue.record("could not find Package.swift from \(#filePath)")
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func makeTemplateHost(arch: String, bridged: Bool) -> HostInventory {
    HostInventory(
        schemaVersion: 1,
        hostId: "test-host-id",
        displayName: "test-host",
        agent: AgentInfo(version: "test"),
        platform: PlatformInfo(os: "macOS", osVersion: "test", arch: arch, hostname: "test-host"),
        resources: ResourcesInfo(
            cpuCount: 4, memoryTotalMB: 8_192, memoryUsedMB: 1_024, cpuLoadPercent: 1,
        ),
        storage: [],
        networking: NetworkingInfo(interfaces: []),
        virtualization: VirtualizationInfo(
            accelerator: "hvf",
            qemuCPUModel: "host",
            defaultGuestArch: arch == "arm64" ? "aarch64" : "x86_64",
            features: VirtualizationFeatures(
                bridgedNetworking: bridged,
                managedBridgeDaemon: bridged,
                usbPassthrough: true,
                inAppUpdate: true,
                kvmDevice: false,
                qemuBridgeHelper: false,
            ),
        ),
        guestTypes: [],
        collectedAt: "2026-08-12T00:00:00Z",
    )
}

private actor ArchStubImageDownloader: ImageDownloadStarting {
    private(set) var startedURLs: [URL] = []

    func start(
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum?,
    ) {
        startedURLs.append(url)
    }
}
