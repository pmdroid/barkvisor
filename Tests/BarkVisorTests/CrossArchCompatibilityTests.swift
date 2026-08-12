import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct CrossArchCompatibilityTests {
    // MARK: - Arch normalization

    @Test func `normalizedArch maps common aliases`() {
        #expect(PlatformCapabilities.normalizedArch("arm64") == "arm64")
        #expect(PlatformCapabilities.normalizedArch("aarch64") == "arm64")
        #expect(PlatformCapabilities.normalizedArch("x86_64") == "x86_64")
        #expect(PlatformCapabilities.normalizedArch("amd64") == "x86_64")
        // Align with frontend normalizeImageArch (case, trim, x64).
        #expect(PlatformCapabilities.normalizedArch("x64") == "x86_64")
        #expect(PlatformCapabilities.normalizedArch("X86_64") == "x86_64")
        #expect(PlatformCapabilities.normalizedArch("AMD64") == "x86_64")
        #expect(PlatformCapabilities.normalizedArch(" AArch64 ") == "arm64")
    }

    // MARK: - Create/deploy validation wiring

    /// `validateCreateVMInputs` is shared by create + template deploy.
    @Test func `validateCreateVMInputs blocks foreign guest arch`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(pool)

        let host = PlatformCapabilities.hostArch
        let foreignType = host == "arm64" ? "linux-amd64" : "linux-arm64"
        let params = CreateVMParams(
            name: "cross-arch-guard",
            vmType: foreignType,
            cpuCount: 1,
            memoryMB: 512,
            cloudImageId: "img-unused",
        )

        do {
            try await VMLifecycleService.validateCreateVMInputs(params: params, db: pool)
            Issue.record("expected validateCreateVMInputs to reject \(foreignType) on \(host)")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.lowercased().contains("not compatible")
                || message.lowercased().contains("cross-architecture"))
            #expect(message.contains(host))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Host ↔ guest compatibility

    @Test func `same arch guest is compatible`() {
        let host = PlatformCapabilities.hostArch
        #expect(PlatformCapabilities.isCompatibleGuestArch(host))
        #expect(throws: Never.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(host)
        }
        // Aliases of the host arch must also pass.
        if host == "arm64" {
            #expect(PlatformCapabilities.isCompatibleGuestArch("aarch64"))
            #expect(throws: Never.self) {
                try PlatformCapabilities.requireCompatibleGuestArch("aarch64")
            }
        } else if host == "x86_64" {
            #expect(PlatformCapabilities.isCompatibleGuestArch("amd64"))
            #expect(throws: Never.self) {
                try PlatformCapabilities.requireCompatibleGuestArch("amd64")
            }
        }
    }

    @Test func `cross arch guest is blocked with clear reason`() {
        let host = PlatformCapabilities.hostArch
        let foreign = host == "arm64" ? "x86_64" : "arm64"

        #expect(!PlatformCapabilities.isCompatibleGuestArch(foreign))

        do {
            try PlatformCapabilities.requireCompatibleGuestArch(foreign)
            Issue.record("expected requireCompatibleGuestArch to throw for \(foreign) on \(host)")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.contains(foreign))
            #expect(message.contains(host))
            #expect(message.lowercased().contains("not compatible")
                || message.lowercased().contains("cross-architecture"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Core PAS-48 matrix case expressed relative to the running host:
    /// foreign GuestProfile.arch must be rejected before QEMU is launched.
    @Test func `foreign guest profile arch is rejected`() throws {
        let host = PlatformCapabilities.hostArch
        let foreignProfiles = GuestProfiles.all.filter { $0.arch != host }
        #expect(!foreignProfiles.isEmpty)

        for profile in foreignProfiles {
            #expect(!PlatformCapabilities.isCompatibleGuestArch(profile.arch))
            #expect(throws: BarkVisorError.self) {
                try PlatformCapabilities.requireCompatibleGuestArch(profile.arch)
            }
        }

        let nativeProfiles = GuestProfiles.all.filter { $0.arch == host }
        #expect(!nativeProfiles.isEmpty)
        for profile in nativeProfiles {
            try PlatformCapabilities.requireCompatibleGuestArch(profile.arch)
        }
    }

    /// Acceptance-criteria direction (PAS-48): x86_64 workload on arm64 host.
    @Test(.enabled(if: PlatformCapabilities.hostArch == "arm64"))
    func `x86_64 workload blocked on arm64 host`() throws {
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch("x86_64")
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                GuestProfiles.require("linux-amd64").arch,
            )
        }
    }

    /// Template deploy rejects foreign-arch catalog images before download starts (PAS-48 P1).
    /// Exercises `TemplateDeployService.deploy` so removing the gate at resolve time fails this test.
    @Test func `template deploy rejects foreign arch before download`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(pool)

        let host = PlatformCapabilities.hostArch
        let foreignArch = host == "arm64" ? "x86_64" : "arm64"
        let now = iso8601.string(from: Date())
        let repoId = UUID().uuidString
        let templateId = UUID().uuidString
        let imageSlug = "foreign-cloud-\(foreignArch)"

        try await pool.write { db in
            try ImageRepository(
                id: repoId,
                name: "test-templates",
                url: "https://example.com/catalog.json",
                isBuiltIn: false,
                repoType: "templates",
                lastSyncedAt: nil,
                lastError: nil,
                syncStatus: "idle",
                createdAt: now,
                updatedAt: now,
            ).insert(db)

            try RepositoryImage(
                id: UUID().uuidString,
                repositoryId: repoId,
                slug: imageSlug,
                name: "Foreign Cloud",
                description: nil,
                imageType: "cloud",
                arch: foreignArch,
                version: "1",
                downloadUrl: "https://example.com/\(imageSlug).qcow2",
                sizeBytes: 1_024,
            ).insert(db)

            try VMTemplate(
                id: templateId,
                slug: "foreign-tmpl",
                name: "Foreign Template",
                description: nil,
                category: "general",
                icon: "terminal",
                imageSlug: imageSlug,
                cpuCount: 1,
                memoryMB: 512,
                diskSizeGB: 8,
                portForwards: "[]",
                networkMode: "nat",
                inputs: "[]",
                userDataTemplate: "",
                isBuiltIn: false,
                repositoryId: repoId,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        // Stub downloader: start must never run when the arch gate fires first.
        let downloader = StubImageDownloader()
        let backgroundTasks = BackgroundTaskManager()

        do {
            _ = try await TemplateDeployService.deploy(
                options: DeployOptions(
                    templateId: templateId,
                    vmName: "cross-arch-deploy",
                    inputs: [:],
                ),
                imageDownloader: downloader,
                backgroundTasks: backgroundTasks,
                db: pool,
            )
            Issue.record("expected deploy to reject foreign arch \(foreignArch) on \(host)")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.lowercased().contains("not compatible")
                || message.lowercased().contains("cross-architecture"))
            #expect(message.contains(host))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await downloader.startCallCount == 0)
        let imageCount = try await pool.read { db in
            try VMImage.fetchCount(db)
        }
        #expect(imageCount == 0, "download must not start for foreign-arch template deploy")
    }

    /// Symmetric guard on x86_64 CI/dev hosts.
    @Test(.enabled(if: PlatformCapabilities.hostArch == "x86_64"))
    func `arm64 workload blocked on x86_64 host`() throws {
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch("arm64")
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                GuestProfiles.require("linux-arm64").arch,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                GuestProfiles.require("windows-arm64").arch,
            )
        }
    }
}

/// Test double for `ImageDownloadStarting` — records whether `start` was invoked.
private actor StubImageDownloader: ImageDownloadStarting {
    private(set) var startCallCount = 0

    func start(
        imageID: String, url: URL, destination: URL, expectedChecksum: ExpectedChecksum?,
    ) {
        startCallCount += 1
    }
}
