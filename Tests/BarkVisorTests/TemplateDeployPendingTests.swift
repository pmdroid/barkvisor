import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct TemplateDeployPendingTests {
    @Test func `download deploy inserts a VM before the image is ready`() async throws {
        let (pool, tmp) = try makePendingDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/cloud-\(host).qcow2"
        let downloader = PendingStubDownloader()
        let tasks = BackgroundTaskManager()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "pending-box",
                inputs: [:],
                recipe: pendingRecipe(arch: host, url: url),
            ),
            imageDownloader: downloader,
            backgroundTasks: tasks,
            db: pool,
        )
        guard case let .downloading(imageId, vm) = result else {
            Issue.record("expected downloading with VM, got \(result)")
            return
        }
        #expect(vm.state == "provisioning")
        #expect(!imageId.isEmpty)
        let stored = try await pool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(stored != nil)
        let disk = try await pool.read { db in try Disk.fetchOne(db, key: vm.bootDiskId) }
        #expect(disk?.status == "creating")
        let pending = try await pool.read { db in
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == vm.id).fetchOne(db)
        }
        #expect(pending?.imageId == imageId)
        #expect(await downloader.startedURLs.contains { $0.absoluteString == url })
        let second = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "pending-box",
                inputs: [:],
                recipe: pendingRecipe(arch: host, url: url),
            ),
            imageDownloader: downloader,
            backgroundTasks: BackgroundTaskManager(),
            db: pool,
        )
        guard case let .downloading(_, again) = second else {
            Issue.record("expected idempotent downloading, got \(second)")
            return
        }
        #expect(again.id == vm.id)
        let count = try await pool.read { db in try VM.fetchCount(db) }
        #expect(count == 1)
        await tasks.cancelAll()
    }

    @Test func `ready image skips downloading and creates one VM`() async throws {
        let (pool, tmp) = try makePendingDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/ready-\(host).qcow2"
        let path = tmp.appendingPathComponent("ready.qcow2").path
        FileManager.default.createFile(atPath: path, contents: Data("qcow".utf8))
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try VMImage(
                id: "img-ready",
                name: "Cloud",
                imageType: "cloud-image",
                arch: host,
                path: path,
                sizeBytes: 4,
                status: "ready",
                error: nil,
                sourceUrl: url,
                sha256: "aaaaaaaa",
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
        let tasks = BackgroundTaskManager()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "ready-box",
                inputs: [:],
                recipe: pendingRecipe(arch: host, url: url),
            ),
            imageDownloader: PendingStubDownloader(),
            backgroundTasks: tasks,
            db: pool,
        )
        switch result {
        case .downloading:
            Issue.record("ready image should not return downloading")
        case let .provisioning(_, vm), let .created(vm):
            #expect(vm.name == "ready-box")
        }
        let count = try await pool.read { db in try VM.fetchCount(db) }
        #expect(count == 1)
        await tasks.cancelAll()
    }

    @Test func `image ready continues without a second deploy call`() async throws {
        let (pool, tmp) = try makePendingDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/wait-\(host).qcow2"
        let tasks = BackgroundTaskManager()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "wait-box",
                inputs: [:],
                recipe: pendingRecipe(arch: host, url: url),
            ),
            imageDownloader: PendingStubDownloader(),
            backgroundTasks: tasks,
            db: pool,
        )
        guard case let .downloading(imageId, vm) = result else {
            Issue.record("expected downloading, got \(result)")
            await tasks.cancelAll()
            return
        }
        let qcow = tmp.appendingPathComponent("src.qcow2")
        FileManager.default.createFile(atPath: qcow.path, contents: Data("disk".utf8))
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try db.execute(
                sql: """
                UPDATE images SET status = 'ready', path = ?, updatedAt = ? WHERE id = ?
                """,
                arguments: [qcow.path, now, imageId],
            )
        }
        var pendingGone = false
        for _ in 0 ..< 80 {
            let remaining = try await pool.read { db in
                try PendingDeploy.filter(PendingDeploy.Columns.vmId == vm.id).fetchCount(db)
            }
            if remaining == 0 {
                pendingGone = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(pendingGone)
        let after = try await pool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(after != nil)
        #expect(after?.state == "provisioning" || after?.state == "stopped" || after?.state == "error")
        let clone = await tasks.status("disk-clone:\(vm.id)")
        let finish = await tasks.status(TemplateDeployService.deployTaskID(vmID: vm.id))
        #expect(clone != nil || finish != nil)
        await tasks.cancelAll()
    }

    @Test func `image error marks the VM retryable`() async throws {
        let (pool, tmp) = try makePendingDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/fail-\(host).qcow2"
        let tasks = BackgroundTaskManager()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "fail-box",
                inputs: [:],
                recipe: pendingRecipe(arch: host, url: url),
            ),
            imageDownloader: PendingStubDownloader(),
            backgroundTasks: tasks,
            db: pool,
        )
        guard case let .downloading(imageId, vm) = result else {
            Issue.record("expected downloading, got \(result)")
            await tasks.cancelAll()
            return
        }
        let now = iso8601.string(from: Date())
        try await pool.write { db in
            try db.execute(
                sql: """
                UPDATE images SET status = 'error', error = ?, updatedAt = ? WHERE id = ?
                """,
                arguments: ["checksum mismatch", now, imageId],
            )
        }
        var errored: VM?
        for _ in 0 ..< 80 {
            let row = try await pool.read { db in try VM.fetchOne(db, key: vm.id) }
            if row?.state == "error" {
                errored = row
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(errored?.state == "error")
        #expect(errored?.description?.contains("checksum mismatch") == true)
        #expect(errored?.description?.lowercased().contains("retry") == true)
        let remaining = try await pool.read { db in
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == vm.id).fetchCount(db)
        }
        #expect(remaining == 0)
        await tasks.cancelAll()
    }

    @Test func `resume pending submit is idempotent`() async throws {
        let (pool, tmp) = try makePendingDB()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let host = PlatformCapabilities.hostArch
        let url = "https://example.com/resume-\(host).qcow2"
        let tasks = BackgroundTaskManager()
        let downloader = PendingStubDownloader()
        let result = try await TemplateDeployService.deploy(
            options: DeployOptions(
                templateId: "tpl",
                vmName: "resume-box",
                inputs: [:],
                recipe: pendingRecipe(arch: host, url: url),
            ),
            imageDownloader: downloader,
            backgroundTasks: tasks,
            db: pool,
        )
        guard case let .downloading(_, vm) = result else {
            Issue.record("expected downloading, got \(result)")
            await tasks.cancelAll()
            return
        }
        let taskID = TemplateDeployService.deployTaskID(vmID: vm.id)
        await TemplateDeployService.resumePending(
            imageDownloader: downloader,
            backgroundTasks: tasks,
            db: pool,
        )
        let first = await tasks.status(taskID)
        #expect(first?.status == .running || first?.status == .queued)
        await tasks.cancelAll()
        await TemplateDeployService.resumePending(
            imageDownloader: downloader,
            backgroundTasks: tasks,
            db: pool,
        )
        let again = await tasks.status(taskID)
        #expect(again?.status == .running || again?.status == .queued)
        await tasks.cancelAll()
    }
}

private actor PendingStubDownloader: ImageDownloadStarting {
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

private func pendingRecipe(arch: String, url: String) -> DeployRecipe {
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
        ),
    )
}

private func makePendingDB() throws -> (DatabasePool, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    return (pool, tmp)
}
