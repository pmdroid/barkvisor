import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// A VM/Workload attach racing a network mode change (#634).
///
/// Two attach seams resolve and validate the network in one read, then persist
/// the row in a *separate* write transaction, so a mode change landing in that
/// gap could persist a network/Workload pair that can no longer launch:
/// `createVM` → `insertVMAndDisk`, and `TemplateDeployService` →
/// `insertPlaceholder`. Each re-checks the mode inside its own insert
/// transaction now.
final class NetworkPortForwardRaceTests {
    private let tmpDir: URL
    private let dbPath: String
    private let dbPool: DatabasePool
    private let now = "2025-01-01T00:00:00Z"

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        dbPath = tmp.appendingPathComponent("test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(dbPool)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private var hostLinux: String {
        GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
    }

    private var cpuCount: Int {
        min(2, max(1, PlatformHost.cpuCount))
    }

    /// A NAT network plus one free disk, so `createVM` reaches `insertVMAndDisk`.
    private func seedNATNetwork(_ pool: DatabasePool, tmpDir: URL) async throws {
        try await pool.write { db in
            try Network(
                id: "net-race", name: "race", mode: "nat", bridge: nil,
                macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
            ).insert(db)
            let path = tmpDir.appendingPathComponent("boot.qcow2").path
            _ = FileManager.default.createFile(atPath: path, contents: Data())
            try Disk(
                id: "disk-boot", name: "boot", path: path, sizeBytes: 1_024,
                format: "qcow2", vmId: nil, autoCreated: false, status: "ready",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }
    }

    private func createParams() -> CreateVMParams {
        CreateVMParams(
            id: nil, name: "racer", vmType: hostLinux,
            cpuCount: cpuCount, memoryMB: 512, networkId: "net-race",
            existingDiskId: "disk-boot",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 9_900, guestPort: 80)],
        )
    }

    /// Flip the network to isolated from a second connection the first time the
    /// traced pool runs a statement containing `trigger`.
    ///
    /// Blocking the trace callback on a semaphore pins the interleaving: the
    /// trigger is chosen to be a statement inside a `db.read` that runs *after*
    /// the seam has resolved and validated the network but *before* it opens the
    /// write transaction that persists the row. Parked there, the pool holds no
    /// write lock, so the flip can commit from a separate pool.
    private func flipNetwork(
        id networkID: String = "net-race",
        on trigger: String,
    ) async throws -> ModeFlip {
        let flipPool = try DatabasePool(path: dbPath)
        let hook = FlipHook()
        let armed = ArmOnce()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                guard case let .statement(statement) = event else { return }
                guard statement.sql.contains(trigger) else { return }
                guard armed.claim() else { return }
                hook.begin()
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        try await flipPool.write { db in
                            try db.execute(
                                sql: "UPDATE networks SET mode = 'isolated' WHERE id = ?",
                                arguments: [networkID],
                            )
                        }
                        hook.succeed()
                    } catch {
                        hook.fail(error)
                    }
                    done.signal()
                }
                done.wait()
            }
        }
        let tracedPool = try DatabasePool(path: dbPath, configuration: config)
        try AppDatabase.makeMigrator().migrate(tracedPool)
        return ModeFlip(pool: tracedPool, hook: hook)
    }

    @Test func `createVM re-checks the network inside the insert transaction`() async throws {
        try await seedNATNetwork(dbPool, tmpDir: tmpDir)
        // `PortRegistry.claims` reads the VMs in its own `db.read`, after
        // `validateCreateVMInputs` has seen NAT and before `insertVMAndDisk`
        // opens its write transaction.
        let flip = try await flipNetwork(on: "FROM \"vms\"")

        let error = await #expect(throws: BarkVisorError.self) {
            try await VMLifecycleService.createVM(
                params: self.createParams(), db: flip.pool, backgroundTasks: BackgroundTaskManager(),
            )
        }

        // The hook must actually have fired, or this test proves nothing.
        #expect(flip.hook.didFire)
        #expect(error?.errorDescription?.contains("Port forwards require NAT") == true)

        // The mode change committed while create was parked...
        let network = try await dbPool.read { db in try Network.fetchOne(db, key: "net-race") }
        #expect(network?.mode == "isolated")
        // ...and the invalid pair was never persisted: no VM row, so no claim
        // that a running QEMU could still be holding a socket for.
        let vmCount = try await dbPool.read { db in try VM.fetchCount(db) }
        #expect(vmCount == 0)
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.isEmpty)
    }

    @Test func `concurrent createVM and mode change never persist an unlaunchable pair`() async throws {
        // The hook above pins one interleaving. This one lets them genuinely
        // race, and only asserts the invariant that must hold on every
        // interleaving: no forwarding VM on a network without hostfwd.
        let hostLinux = self.hostLinux
        let cpuCount = self.cpuCount
        let tmpDir = self.tmpDir
        for attempt in 0 ..< 15 {
            let networkID = "net-race-\(attempt)"
            try await dbPool.write { db in
                try Network(
                    id: networkID, name: networkID, mode: "nat", bridge: nil,
                    macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
                ).insert(db)
                let path = tmpDir.appendingPathComponent("boot-\(attempt).qcow2").path
                _ = FileManager.default.createFile(atPath: path, contents: Data())
                try Disk(
                    id: "disk-\(attempt)", name: "boot", path: path, sizeBytes: 1_024,
                    format: "qcow2", vmId: nil, autoCreated: false, status: "ready",
                    createdAt: "2025-01-01T00:00:00Z",
                ).insert(db)
            }
            let params = CreateVMParams(
                id: nil, name: "racer-\(attempt)", vmType: hostLinux,
                cpuCount: cpuCount, memoryMB: 512, networkId: networkID,
                existingDiskId: "disk-\(attempt)",
                portForwards: [
                    PortForwardRule(protocol: "tcp", hostPort: 9_700 + attempt, guestPort: 80),
                ],
            )
            let pool = dbPool
            async let create: Bool = Self.createSucceeds(params, pool)
            async let flip: Bool = Self.flipToIsolated(pool, networkID)
            let created = await create
            let flipped = await flip

            let network = try await dbPool.read { db in try Network.fetchOne(db, key: networkID) }
            let vms = try await dbPool.read { db in try VM.filter(Column("networkId") == networkID).fetchAll(db) }
            if network?.mode == "isolated" {
                // Mode change won: no forwarding VM may be left attached.
                #expect(vms.isEmpty)
            } else {
                #expect(network?.mode == "nat")
                if created {
                    #expect(vms.count == 1)
                    #expect(vms.first?.decodedPortForwards.count == 1)
                } else {
                    #expect(vms.isEmpty)
                }
            }
            #expect(!(created && flipped))
        }
    }

    // MARK: - Template deploy placeholder

    private func seedDeployLibrary(_ pool: DatabasePool) async throws {
        let library = tmpDir.appendingPathComponent("library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try await pool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
            try Network(
                id: "net-deploy", name: "deploy", mode: "nat", bridge: nil,
                macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
            ).insert(db)
        }
    }

    private func deployOptions(
        name: String, networkID: String, hostPort: Int,
    ) -> DeployOptions {
        let arch = PlatformCapabilities.hostArch
        return DeployOptions(
            templateId: "tpl", vmName: name, inputs: [:], networkId: networkID,
            recipe: DeployRecipe(
                name: "Cloud", slug: "cloud", inputs: [],
                userDataTemplate: "", cpuCount: 1, memoryMB: 512, diskSizeGB: 8,
                portForwards: [PortForwardRule(protocol: "tcp", hostPort: hostPort, guestPort: 80)],
                architectures: [arch],
                image: DeployRecipeImage(
                    downloadUrl: "https://example.com/\(name).qcow2", arch: arch,
                    imageType: "cloud-image", sha256: "aaaaaaaa", slug: "cloud-\(name)",
                    sizeBytes: 1,
                ),
            ),
        )
    }

    @Test func `template deploy re-checks the network inside the placeholder insert`() async throws {
        try await seedDeployLibrary(dbPool)
        // `insertPlaceholder` resolves the network in its own read, then reads
        // `app_settings` for the disk directory, then opens its write
        // transaction. Park on that middle read.
        let flip = try await flipNetwork(id: "net-deploy", on: "FROM \"app_settings\"")

        let error = await #expect(throws: BarkVisorError.self) {
            try await TemplateDeployService.deploy(
                options: self.deployOptions(
                    name: "racer", networkID: "net-deploy", hostPort: 9_950,
                ),
                imageDownloader: RaceStubDownloader(),
                backgroundTasks: BackgroundTaskManager(),
                db: flip.pool,
            )
        }

        #expect(flip.hook.didFire)
        #expect(error?.errorDescription?.contains("Port forwards require NAT") == true)

        let network = try await dbPool.read { db in try Network.fetchOne(db, key: "net-deploy") }
        #expect(network?.mode == "isolated")
        // The placeholder must not exist, so no claim can be stranded behind a
        // running QEMU.
        let vms = try await dbPool.read { db in
            try VM.filter(Column("networkId") == "net-deploy").fetchAll(db)
        }
        #expect(vms.isEmpty)
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.isEmpty)
    }

    @Test func `template deploy still succeeds when the mode does not change under it`() async throws {
        try await seedDeployLibrary(dbPool)
        let result = try await TemplateDeployService.deploy(
            options: deployOptions(name: "ok", networkID: "net-deploy", hostPort: 9_951),
            imageDownloader: RaceStubDownloader(),
            backgroundTasks: BackgroundTaskManager(),
            db: dbPool,
        )
        guard case let .downloading(_, vm) = result else {
            Issue.record("expected downloading, got \(result)")
            return
        }
        #expect(vm.state == "provisioning")
        #expect(vm.networkId == "net-deploy")
        #expect(vm.decodedPortForwards.count == 1)
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.contains { $0.hostPort == 9_951 })
    }

    private static func createSucceeds(_ params: CreateVMParams, _ pool: DatabasePool) async -> Bool {
        do {
            _ = try await VMLifecycleService.createVM(
                params: params, db: pool, backgroundTasks: BackgroundTaskManager(),
            )
            return true
        } catch {
            return false
        }
    }

    private static func flipToIsolated(_ pool: DatabasePool, _ id: String) async -> Bool {
        do {
            _ = try await NetworkService.update(
                UpdateNetworkParams(
                    id: id, name: nil, mode: "isolated",
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: pool,
            )
            return true
        } catch {
            return false
        }
    }

    @Test func `createVM still succeeds when the mode does not change under it`() async throws {
        try await seedNATNetwork(dbPool, tmpDir: tmpDir)
        // No hook: nothing withdraws hostfwd, so the same create must succeed.
        let result = try await VMLifecycleService.createVM(
            params: createParams(), db: dbPool, backgroundTasks: BackgroundTaskManager(),
        )
        let vmID: String =
            switch result {
            case let .created(vm): vm.id
            case let .provisioning(_, vm): vm.id
            }
        let vm = try #require(try await dbPool.read { db in try VM.fetchOne(db, key: vmID) })
        #expect(vm.networkId == "net-race")
        #expect(vm.decodedPortForwards.count == 1)
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.contains { $0.hostPort == 9_900 })
    }
}

// MARK: - Helpers

private struct ModeFlip {
    let pool: DatabasePool
    let hook: FlipHook
}

private actor RaceStubDownloader: ImageDownloadStarting {
    func start(
        imageID: String,
        url: URL,
        destination: URL,
        expectedChecksum: ExpectedChecksum?,
        expectedStoredSha256: String?,
    ) {}
}

/// Fires the `PortRegistry.claims` flip at most once.
private final class ArmOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var spent = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if spent { return false }
        spent = true
        return true
    }
}

private final class FlipHook: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func begin() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    func succeed() {}

    func fail(_ error: Error) {
        Issue.record("mode flip failed: \(error)")
    }
}
