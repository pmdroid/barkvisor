import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// BV-07: an interrupted cloud-image clone must resolve within one restart, for both the
/// generic create path and the template path. These drive the durable `vm.provision` operation
/// directly with a fake clone, so the crash points are exact and no `qemu-img` is needed.
@Suite(.serialized)
struct VMProvisionRecoveryTests {
    @Test(
        arguments: [
            VMProvision.phaseAccepted,
            VMProvision.phaseCloning,
            VMProvision.phaseDiskReady,
            VMProvision.phaseFinalised,
        ],
    )
    func `a provision interrupted at any phase resolves within one restart`(_ point: String) async throws {
        let harness = try await ProvisionHarness()

        // 1. The clone dies at `point`, exactly as a daemon crash would.
        try await harness.run {
            try await WorkloadEffectGate.$hook.withValue({ phase in
                if phase == point { throw WorkloadOperationInterrupted() }
            }) {
                _ = await #expect(throws: WorkloadOperationInterrupted.self) {
                    try await VMProvision.drive(
                        record: harness.operation, db: harness.db.pool, report: nil,
                    )
                }
            }
        }
        let interrupted = try #require(
            try await WorkloadOperationStore.fetch(db: harness.db.pool, id: harness.operation.id),
        )
        // The record stays open so the next startup can resume it. Up to and including
        // `disk_ready` the workload is still `provisioning` under that record — the whole point
        // of the operation. From `finalised` the row write has landed and only the completion
        // is outstanding.
        #expect(interrupted.isOpen)
        #expect(interrupted.phase == point)
        let stillProvisioning = point != VMProvision.phaseFinalised
        #expect(try await harness.state() == (stillProvisioning ? "provisioning" : "stopped"))
        #expect(try await harness.disk()?.status == (stillProvisioning ? "creating" : "ready"))

        // 2. One restart resumes and finishes it.
        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        try await harness.assertProvisioned()

        // 3. Partial work is idempotent: another restart changes nothing.
        let clonesBefore = harness.clones
        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        #expect(harness.clones == clonesBefore)
        try await harness.assertProvisioned()
    }

    @Test func `a crash before the clone clones once on resume`() async throws {
        let harness = try await ProvisionHarness()
        // The daemon died between accepting the record and starting the clone.
        let interrupted = try #require(
            try await WorkloadOperationStore.fetch(db: harness.db.pool, id: harness.operation.id),
        )
        #expect(interrupted.phase == VMProvision.phaseAccepted)
        #expect(harness.clones == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.destination.path))

        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        // Exactly one clone: the resume did the work the crash skipped, and no more.
        #expect(harness.clones == 1)
        try await harness.assertProvisioned()
    }

    @Test func `a half-written destination is discarded and re-cloned, never resumed in place`() async throws {
        let harness = try await ProvisionHarness()
        // Mid-clone: the record is past `accepted` and a partial file is on disk. This is the
        // case that decides what "resume" means — a truncated qcow2 cannot be continued.
        // A qcow2 magic prefix followed by a stub: the shape `qemu-img` leaves when it dies.
        try Data([UInt8(ascii: "Q"), UInt8(ascii: "F"), UInt8(ascii: "I"), 0xFB] + Array("partial".utf8))
            .write(to: harness.destination)
        try await harness.run {
            try await WorkloadEffectGate.$hook.withValue({ phase in
                if phase == VMProvision.phaseCloning { throw WorkloadOperationInterrupted() }
            }) {
                _ = await #expect(throws: WorkloadOperationInterrupted.self) {
                    try await VMProvision.drive(
                        record: harness.operation, db: harness.db.pool, report: nil,
                    )
                }
            }
        }
        #expect(try await harness.state() == "provisioning")

        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        // The partial bytes are gone — the destination was thrown away, not appended to.
        let body = try String(contentsOf: harness.destination, encoding: .utf8)
        #expect(body == harness.clonedBody)
        #expect(!body.contains("partial"))
        try await harness.assertProvisioned()
    }

    @Test func `a completed clone is not written a second time`() async throws {
        let harness = try await ProvisionHarness()
        // Crash after the clone but before the DB finalisation: the destination is whole.
        try await harness.run {
            try await WorkloadEffectGate.$hook.withValue({ phase in
                if phase == VMProvision.phaseDiskReady { throw WorkloadOperationInterrupted() }
            }) {
                _ = await #expect(throws: WorkloadOperationInterrupted.self) {
                    try await VMProvision.drive(
                        record: harness.operation, db: harness.db.pool, report: nil,
                    )
                }
            }
        }
        #expect(harness.clones == 1)
        // The disk row is still `creating` and the VM still `provisioning` — the window the
        // operation exists to close.
        #expect(try await harness.disk()?.status == "creating")
        #expect(try await harness.state() == "provisioning")

        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        // The finished clone is trusted: no second write to the destination.
        #expect(harness.clones == 1)
        try await harness.assertProvisioned()
    }

    @Test func `a clone checkpointed done but with an unreadable destination re-clones`() async throws {
        let harness = try await ProvisionHarness()
        try await harness.run {
            try await WorkloadEffectGate.$hook.withValue({ phase in
                if phase == VMProvision.phaseDiskReady { throw WorkloadOperationInterrupted() }
            }) {
                _ = try? await VMProvision.drive(
                    record: harness.operation, db: harness.db.pool, report: nil,
                )
            }
        }
        #expect(harness.clones == 1)
        // The person (or a lost write) took the file away after the clone was checkpointed. The
        // record is still open at `disk_ready`, so this is a resumed provision, not a retry.
        try? FileManager.default.removeItem(at: harness.destination)
        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        #expect(harness.clones == 2)
        try await harness.assertProvisioned()
    }

    @Test func `a missing source image fails the provision and leaves the workload usable`() async throws {
        let harness = try await ProvisionHarness()
        try? FileManager.default.removeItem(atPath: harness.source.path)
        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        #expect(try await harness.state() == "error")
        #expect(try await harness.disk()?.status == "creating")
        #expect(!FileManager.default.fileExists(atPath: harness.destination.path))
        // `error` is a state both start and delete accept, so the workload is not stranded.
        let recovered = try #require(try await harness.storedVM())
        #expect(recovered.state == "error")
        #expect(VMLifecycleService.canDelete(recovered))
        let failed = try #require(
            try await WorkloadOperationStore.fetch(db: harness.db.pool, id: harness.operation.id),
        )
        #expect(failed.status == WorkloadOperationStatus.failed)
        #expect(failed.recoveryOutcome == VMProvision.outcomeSourceMissing)
        #expect(failed.isRetryable)
    }

    @Test func `a retry after a failed clone succeeds`() async throws {
        let harness = try await ProvisionHarness()
        // The clone fails for a reason the retry does not have.
        try await harness.run(failingClone: true) {
            _ = await #expect(throws: BarkVisorError.self) {
                try await VMProvision.drive(
                    record: harness.operation, db: harness.db.pool, report: nil,
                )
            }
        }
        #expect(try await harness.state() == "error")
        let failed = try #require(
            try await WorkloadOperationStore.fetch(db: harness.db.pool, id: harness.operation.id),
        )
        #expect(failed.status == WorkloadOperationStatus.failed)
        #expect(failed.isRetryable)
        // The partial destination was removed, so the retry starts from a clean path.
        #expect(!FileManager.default.fileExists(atPath: harness.destination.path))

        try await harness.run {
            try await ApplicationDeployment.retry(
                db: harness.db.pool, operationID: harness.operation.id, dataDir: harness.db.dir,
            )
        }
        try await harness.assertProvisioned()
    }

    @Test func `the template marker is not cleared while a clone is still outstanding`() async throws {
        let harness = try await ProvisionHarness(template: true)
        try await harness.run {
            try await WorkloadEffectGate.$hook.withValue({ phase in
                if phase == VMProvision.phaseCloning { throw WorkloadOperationInterrupted() }
            }) {
                _ = await #expect(throws: WorkloadOperationInterrupted.self) {
                    try await VMProvision.drive(
                        record: harness.operation, db: harness.db.pool, report: nil,
                    )
                }
            }
        }
        // The `pending_deploys` row is the template path's resume marker; it must still be there.
        #expect(try await harness.pendingDeploy() != nil)

        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        try await harness.assertProvisioned()
        // Only a terminal provision clears it.
        #expect(try await harness.pendingDeploy() == nil)
    }

    @Test func `a failed template clone clears the marker and marks the deploy failed`() async throws {
        let harness = try await ProvisionHarness(template: true)
        try? FileManager.default.removeItem(atPath: harness.source.path)
        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        #expect(try await harness.pendingDeploy() == nil)
        #expect(try await harness.state() == "error")
    }

    @Test func `a cloud-image create accepts a provision record before the row exists`() async throws {
        // The ordering is the fix: the record is admitted *before* the row is inserted, so a
        // daemon death between the two still leaves a resumption handle rather than a `provisioning`
        // row with nothing owning it.
        let harness = try await ProvisionHarness(seeded: false)
        // `CreateVMResult` is not `Sendable`, so the closure reports the id and the state instead.
        let outcome = try await harness.returning { () -> (String, String) in
            let result = try await VMLifecycleService.createVM(
                params: harness.createParams, db: harness.db.pool,
                backgroundTasks: harness.tasks,
            )
            switch result {
            case let .provisioning(_, vm): return (vm.id, vm.state)
            case let .created(vm): return (vm.id, vm.state)
            }
        }
        #expect(outcome.1 == "provisioning")
        let vmID = outcome.0

        let record = try #require(
            try await WorkloadOperationStore.openOperation(
                db: harness.db.pool, workloadID: vmID, kind: WorkloadOperationKind.vmProvision,
            ),
        )
        let intent = try #require(record.provisionIntent)
        #expect(intent.sourceImagePath == harness.source.path)
        #expect(intent.sizeGB == 20)
        let bootDisk = try await harness.db.pool.read { db in
            try Disk.fetchOne(db, key: intent.diskID)
        }
        #expect(bootDisk?.vmId == vmID)
        // The disk row exists and is still `creating`: the clone has not landed yet.
        #expect(bootDisk?.status == "creating")
        await harness.tasks.cancelAll()
    }

    @Test func `a record with no stored intent fails instead of guessing`() async throws {
        let db = try makeDB()
        let vm = provisionVM(id: "no-intent", state: "provisioning", bootDiskID: nil)
        let row = vm
        try await db.pool.write { database in try row.insert(database) }
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "provision-no-intent",
            workloadID: vm.id,
            kind: WorkloadOperationKind.vmProvision,
            requestedGeneration: 1,
        )
        try await withFakeDisk {
            await WorkloadOperationRecovery.resume(db: db.pool, dataDir: db.dir)
        }
        let failed = try #require(
            try await WorkloadOperationStore.fetch(db: db.pool, id: accepted.record.id),
        )
        #expect(failed.status == WorkloadOperationStatus.failed)
        #expect(failed.recoveryOutcome == VMProvision.outcomeUnresumable)
        let stored = try #require(try await db.pool.read { database in
            try VM.fetchOne(database, key: "no-intent")
        })
        // The workload still exists, so start and delete both work; the person can re-create it.
        #expect(VMLifecycleService.canDelete(stored))
    }

    @Test func `a provision whose workload was deleted completes without touching the row`() async throws {
        let harness = try await ProvisionHarness()
        _ = try await harness.db.pool.write { database in try VM.deleteOne(database, key: harness.vm.id) }
        try await harness.run {
            await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        }
        let done = try #require(
            try await WorkloadOperationStore.fetch(db: harness.db.pool, id: harness.operation.id),
        )
        #expect(done.status == WorkloadOperationStatus.completed)
        #expect(done.recoveryOutcome == VMProvision.outcomeWorkloadMissing)
    }

    @Test func `a provision operation flows through the task and retry surface`() async throws {
        let db = try makeDB()
        let intent = WorkloadProvisionIntent(
            sourceImagePath: "/images/source.qcow2",
            destinationPath: "/disks/boot.qcow2",
            diskID: "disk-prov",
            sizeGB: 20,
            vmName: "box",
        )
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "provision-1",
            workloadID: "vm-prov",
            kind: WorkloadOperationKind.vmProvision,
            requestedGeneration: 2,
            inputPayload: WorkloadProvisionIntent.encode(intent),
        )
        #expect(accepted.record.taskEvent().kind == BackgroundTaskManager.TaskKind.vmProvision.rawValue)
        #expect(accepted.record.provisionIntent == intent)
        #expect(accepted.record.isOpen)
        // A delete intent must not be readable from a provision record.
        #expect(accepted.record.deleteIntent == nil)

        #expect(try await WorkloadOperationStore.complete(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: VMProvision.phaseFinalised,
            recoveryOutcome: VMProvision.outcomeProvisioned,
            resultPayload: "vm-prov",
        ))
        let done = try #require(
            try await WorkloadOperationStore.fetch(db: db.pool, id: accepted.record.id),
        )
        #expect(done.status == WorkloadOperationStatus.completed)
        #expect(done.taskEvent().status == .completed)
        // Completion output stays in `resultPayload`; the intent stays in `inputPayload`.
        #expect(done.provisionIntent?.destinationPath == "/disks/boot.qcow2")
    }

    @Test func `a fresh provision is rejected while a provision is open`() async throws {
        let db = try makeDB()
        _ = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "provision-inflight",
            workloadID: "vm-prov",
            kind: WorkloadOperationKind.vmProvision,
            requestedGeneration: 1,
        )
        _ = await #expect(throws: BarkVisorError.self) {
            _ = try await WorkloadOperationStore.accept(
                db: db.pool,
                idempotencyKey: "provision-fresh",
                workloadID: "vm-prov",
                kind: WorkloadOperationKind.vmProvision,
                requestedGeneration: 1,
            )
        }
    }
}

// MARK: - Harness

private struct TempDB {
    var pool: DatabasePool
    var dir: URL
}

private func makeDB() throws -> TempDB {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    return TempDB(pool: pool, dir: dir)
}

/// A workload mid cloud-image clone: a `provisioning` row, a `creating` disk, a real source
/// image file, and a durable `vm.provision` record holding the clone intent. The clone itself is
/// a fake, so tests observe exactly how many times it ran and what it left behind.
private final class ProvisionHarness: @unchecked Sendable {
    let db: TempDB
    let operation: WorkloadOperationRecord
    let vm: VM
    let source: URL
    let destination: URL
    let tasks: BackgroundTaskManager
    let createParams: CreateVMParams
    static let diskID = "disk-prov"
    let diskID = ProvisionHarness.diskID
    let clonedBody = "complete-clone"
    private let cloneCount = Counter()
    private let failuresLeft = Counter()

    var clones: Int {
        cloneCount.value
    }

    /// `seeded: false` skips the mid-clone workload and record, leaving only a ready cloud image
    /// and the disk directory — the starting point for driving `createVM` itself.
    init(template: Bool = false, seeded: Bool = true) async throws {
        db = try makeDB()
        let disks = db.dir.appendingPathComponent("disks")
        let images = db.dir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        source = images.appendingPathComponent("source.qcow2")
        destination = disks.appendingPathComponent("boot.qcow2")
        try Data("source-image-bytes".utf8).write(to: source)
        tasks = BackgroundTaskManager()

        let host = PlatformCapabilities.hostArch
        let guest = GuestProfiles.defaultLinuxID(forImageArch: host)
        createParams = CreateVMParams(
            name: "guest-prov",
            vmType: guest,
            cpuCount: 2,
            memoryMB: 2_048,
            diskSizeGB: 20,
            cloudImageId: "image-prov",
        )
        let placeholder = provisionVM(
            id: "guest-prov", state: "provisioning", bootDiskID: Self.diskID,
        )
        vm = placeholder
        let pool = db.pool
        let now = "2026-01-01T00:00:00Z"
        let diskPath = destination
        let sourcePath = source
        let imagePath = source
        try await pool.write { database in
            // The Library image the create clones from, and the directory its disk lands in.
            try VMImage(
                id: "image-prov",
                name: "source",
                imageType: "cloud-image",
                arch: host,
                path: imagePath.path,
                sizeBytes: 1_024,
                status: "ready",
                error: nil,
                sourceUrl: nil,
                createdAt: now,
                updatedAt: now,
            ).insert(database)
            try AppSetting(key: DiskSettings.directoryKey, value: diskPath.deletingLastPathComponent().path)
                .save(database, onConflict: .replace)
            guard seeded else { return }
            try Disk(
                id: Self.diskID,
                name: "boot",
                path: diskPath.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: placeholder.id,
                autoCreated: false,
                status: "creating",
                createdAt: now,
            ).insert(database)
            try placeholder.insert(database)
            if template {
                try PendingDeploy(
                    vmId: placeholder.id, imageId: "image-1", payload: "{}", createdAt: now,
                ).insert(database)
            }
        }
        guard seeded else {
            operation = WorkloadOperationRecord(
                id: "", attemptID: "", workloadID: "", kind: "", requestedGeneration: 0,
                phase: "", progress: 0, status: "", idempotencyKey: "", recoveryOutcome: nil,
                resultPayload: nil, inputPayload: nil, error: nil, projectPath: nil,
                dataRestored: 0, createdAt: now, updatedAt: now, finishedAt: nil,
            )
            return
        }
        let accepted = try await WorkloadOperationStore.accept(
            db: pool,
            idempotencyKey: "provision-\(placeholder.id)",
            workloadID: placeholder.id,
            kind: WorkloadOperationKind.vmProvision,
            requestedGeneration: placeholder.specGeneration,
            inputPayload: WorkloadProvisionIntent.encode(
                WorkloadProvisionIntent(
                    sourceImagePath: sourcePath.path,
                    destinationPath: diskPath.path,
                    diskID: Self.diskID,
                    sizeGB: 20,
                    vmName: placeholder.name,
                ),
            ),
        )
        operation = accepted.record
    }

    /// Runs `body` with a fake `qemu-img`: the clone writes a recognisable body and counts runs,
    /// so a test can assert a completed clone is not written a second time.
    @discardableResult
    func run(
        failingClone: Bool = false,
        _ body: @Sendable () async throws -> Void,
    ) async throws {
        if failingClone { failuresLeft.increment() }
        defer { failuresLeft.reset() }
        let counter = cloneCount
        let failures = failuresLeft
        try await VMProvisionEffects.$clone.withValue({ _, dest, _ in
            counter.increment()
            if failures.consume() {
                throw BarkVisorError.diskCreateFailed("no space left on device")
            }
            try Data("complete-clone".utf8).write(to: dest)
        }) {
            try await VMProvisionEffects.$virtualSize.withValue({ _ in 20 * 1_073_741_824 }) {
                try await VMProvisionEffects.$destinationComplete.withValue({ _ in true }) {
                    try await body()
                }
            }
        }
    }

    /// `run`, but returning whatever `body` returns.
    func returning<T: Sendable>(
        _ body: @Sendable () async throws -> T,
    ) async throws -> T {
        try await withDiskEffects(body)
    }

    private func withDiskEffects<T: Sendable>(
        _ body: @Sendable () async throws -> T,
    ) async throws -> T {
        let counter = cloneCount
        let failures = failuresLeft
        return try await VMProvisionEffects.$clone.withValue({ _, dest, _ in
            counter.increment()
            if failures.consume() {
                throw BarkVisorError.diskCreateFailed("no space left on device")
            }
            try Data("complete-clone".utf8).write(to: dest)
        }) {
            try await VMProvisionEffects.$virtualSize.withValue({ _ in 20 * 1_073_741_824 }) {
                try await VMProvisionEffects.$destinationComplete.withValue({ _ in true }) {
                    try await body()
                }
            }
        }
    }

    func state() async throws -> String? {
        try await db.pool.read { db in try VM.fetchOne(db, key: vm.id)?.state }
    }

    func disk() async throws -> Disk? {
        try await db.pool.read { db in try Disk.fetchOne(db, key: diskID) }
    }

    func storedVM() async throws -> VM? {
        try await db.pool.read { db in try VM.fetchOne(db, key: vm.id) }
    }

    func pendingDeploy() async throws -> PendingDeploy? {
        try await db.pool.read { db in
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == vm.id).fetchOne(db)
        }
    }

    func assertProvisioned() async throws {
        #expect(try await state() == "stopped")
        let disk = try #require(try await disk())
        #expect(disk.status == "ready")
        #expect(disk.sizeBytes == 20 * 1_073_741_824)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let done = try #require(
            try await WorkloadOperationStore.fetch(db: db.pool, id: operation.id),
        )
        #expect(done.status == WorkloadOperationStatus.completed)
        #expect(done.recoveryOutcome == VMProvision.outcomeProvisioned)
        #expect(done.phase == VMProvision.phaseFinalised)
    }
}

/// A thread-safe tally, so the fake clone can record runs from any task. Backed by a list
/// rather than an integer so "is there anything left" reads as `isEmpty`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [Bool] = []

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return marks.count
    }

    func increment() {
        lock.lock()
        marks.append(true)
        lock.unlock()
    }

    /// Reads and clears one mark, so a clone fails once and the next attempt succeeds.
    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !marks.isEmpty else { return false }
        marks.removeLast()
        return true
    }

    func reset() {
        lock.lock()
        marks.removeAll()
        lock.unlock()
    }
}

/// A no-op fake for the disk effects, for tests that never reach the clone.
private func withFakeDisk(_ body: @Sendable () async throws -> Void) async throws {
    try await VMProvisionEffects.$clone.withValue({ _, dest, _ in
        try Data("cloned".utf8).write(to: dest)
    }) {
        try await VMProvisionEffects.$virtualSize.withValue({ _ in 1_073_741_824 }) {
            try await VMProvisionEffects.$destinationComplete.withValue({ _ in true }) {
                try await body()
            }
        }
    }
}

private func provisionVM(id: String, state: String, bootDiskID: String?) -> VM {
    VM(
        id: id,
        name: "provisioned-guest",
        vmType: "linux-arm64",
        state: state,
        cpuCount: 2,
        memoryMb: 2_048,
        bootDiskId: bootDiskID,
        isoIds: nil,
        networkId: nil,
        cloudInitPath: nil,
        description: nil,
        bootOrder: nil,
        displayResolution: nil,
        additionalDiskIds: nil,
        uefi: true,
        tpmEnabled: false,
        macAddress: "52:54:00:00:00:01",
        sharedPaths: nil,
        portForwards: nil,
        usbDevices: nil,
        autoCreated: false,
        pendingChanges: false,
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
    )
}
