import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
final class VMLifecycleRecoveryTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    /// The delete tests install process-global compose/docker stubs, so this suite has to hold
    /// the same gate as the other suites that do. Without it, two suites swap each other's
    /// runner mid-test and a teardown reads another suite's `ps` output.
    init() async throws {
        await ComposeSerialGate.acquire()
        ComposeTestIsolation.installFailFast()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
        ComposeTestIsolation.installFailFast()
        Task { await ComposeSerialGate.release() }
    }

    @Test func `handle provision failure marks VM error and removes disk file`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("boot.qcow2")
        FileManager.default.createFile(atPath: diskPath.path, contents: Data("partial".utf8))

        try await dbPool.write { db in
            try Disk(
                id: "disk-1",
                name: "boot",
                path: diskPath.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-1",
                autoCreated: false,
                status: "creating",
                createdAt: now,
            ).insert(db)

            try VM(
                id: "vm-1",
                name: "test-vm",
                vmType: "linux-arm64",
                state: "provisioning",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-1",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: "/tmp/cloud-init/vm-1/cidata.iso",
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        await VMLifecycleService.handleProvisionFailure(
            vmID: "vm-1",
            diskID: "disk-1",
            diskPath: diskPath.path,
            db: dbPool,
            message: "clone failed",
        )

        let vm = try await dbPool.read { db in
            try VM.fetchOne(db, key: "vm-1")
        }
        let disk = try await dbPool.read { db in
            try Disk.fetchOne(db, key: "disk-1")
        }

        #expect(vm?.state == "error")
        #expect(vm?.cloudInitPath == nil)
        #expect(disk?.status == "creating")
        #expect(!FileManager.default.fileExists(atPath: diskPath.path))
    }

    @Test func `handle delete failure marks VM error`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("delete.qcow2")
        FileManager.default.createFile(atPath: diskPath.path, contents: Data())

        try await dbPool.write { db in
            try Disk(
                id: "disk-2",
                name: "boot",
                path: diskPath.path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-2",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)

            try VM(
                id: "vm-2",
                name: "delete-vm",
                vmType: "linux-arm64",
                state: "deleting",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-2",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        await VMLifecycleService.handleDeleteFailure(
            vmID: "vm-2",
            db: dbPool,
            error: BarkVisorError.internalError("boom"),
        )

        let vm = try await dbPool.read { db in
            try VM.fetchOne(db, key: "vm-2")
        }

        #expect(vm?.state == "error")
    }

    @Test func `updateVMSpec metadata only does not set pendingChanges on running VM`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("spec-meta.qcow2").path
        try await dbPool.write { db in
            try Disk(
                id: "disk-spec-meta",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-spec-meta",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: "vm-spec-meta",
                name: "running-vm",
                vmType: "linux-arm64",
                state: "running",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-spec-meta",
                isoIds: #"["iso-1"]"#,
                networkId: nil,
                cloudInitPath: nil,
                description: "old",
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: #"["disk-data"]"#,
                uefi: true,
                tpmEnabled: false,
                macAddress: "52:54:00:00:00:01",
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec-meta") }
        guard var spec = existing.map(WorkloadSpecProjector.fromVM) else {
            Issue.record("expected VM")
            return
        }
        spec.metadata.description = "only metadata"
        spec.spec.disks = []

        let updated = try await VMLifecycleService.updateVMSpec(
            id: "vm-spec-meta", spec: spec, db: dbPool,
        )
        #expect(updated.description == "only metadata")
        #expect(!updated.pendingChanges)
        #expect(updated.decodedISOIds == ["iso-1"])
        #expect(updated.decodedAdditionalDiskIds == ["disk-data"])
    }

    @Test func `updateVMSpec hardware change sets pendingChanges on running VM`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskPath = tmpDir.appendingPathComponent("spec-hw.qcow2").path
        try await dbPool.write { db in
            try Disk(
                id: "disk-spec-hw",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-spec-hw",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: "vm-spec-hw",
                name: "running-hw-vm",
                vmType: "linux-arm64",
                state: "running",
                cpuCount: 2,
                memoryMb: 2_048,
                bootDiskId: "disk-spec-hw",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec-hw") }
        guard var spec = existing.map(WorkloadSpecProjector.fromVM) else {
            Issue.record("expected VM")
            return
        }
        spec.spec.resources.cpu = 1

        let updated = try await VMLifecycleService.updateVMSpec(
            id: "vm-spec-hw", spec: spec, db: dbPool,
        )
        #expect(updated.cpuCount == 1)
        #expect(updated.pendingChanges)
    }

    @Test func `updateVMSpec override-only sets pendingChanges on running VM`() async throws {
        let now = "2026-01-01T00:00:00Z"
        let cpuCount = min(2, max(1, PlatformHost.cpuCount))
        let diskPath = tmpDir.appendingPathComponent("spec-ov.qcow2").path
        try await dbPool.write { db in
            try Disk(
                id: "disk-spec-ov",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-spec-ov",
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: "vm-spec-ov",
                name: "running-ov-vm",
                vmType: "linux-arm64",
                state: "running",
                cpuCount: cpuCount,
                memoryMb: 2_048,
                bootDiskId: "disk-spec-ov",
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }

        let existing = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-spec-ov") }
        guard var spec = existing.map(WorkloadSpecProjector.fromVM) else {
            Issue.record("expected VM")
            return
        }
        spec.overrides = WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
            macos: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
        )

        let updated = try await VMLifecycleService.updateVMSpec(
            id: "vm-spec-ov", spec: spec, db: dbPool,
        )
        #expect(updated.cpuCount == cpuCount)
        #expect(updated.memoryMb == 2_048)
        #expect(updated.decodedOverrides?.linux?.resources?.memoryMb == 4_096)
        #expect(updated.decodedOverrides?.macos?.accelerator == "tcg")
        #expect(updated.pendingChanges)
    }

    @Test func `canDelete allows app pull and start`() {
        #expect(VMLifecycleService.canDelete(recoveryApp(state: "provisioning")))
        #expect(VMLifecycleService.canDelete(recoveryApp(state: "starting")))
        #expect(VMLifecycleService.canDelete(recoveryApp(state: "stopped")))
        #expect(VMLifecycleService.canDelete(recoveryApp(state: "error")))
        #expect(!VMLifecycleService.canDelete(recoveryApp(state: "running")))
        #expect(!VMLifecycleService.canDelete(recoveryApp(state: "deleting")))
        #expect(!VMLifecycleService.canDelete(recoveryVM(state: "provisioning")))
        #expect(!VMLifecycleService.canDelete(recoveryVM(state: "starting")))
        #expect(VMLifecycleService.canDelete(recoveryVM(state: "stopped")))
    }

    @Test func `canDelete admits a VM whose clone is still owned by a provision record`() {
        // A crash mid-clone leaves the row `provisioning` under an open `vm.provision` record.
        // That record will finish or fail the clone, so a delete is not racing an unowned task.
        #expect(VMLifecycleService.canDelete(
            recoveryVM(state: "provisioning"), hasResumableProvision: true,
        ))
        // Both recovery outcomes already land in an admissible state, so they need no extra flag.
        #expect(VMLifecycleService.canDelete(recoveryVM(state: "stopped")))
        #expect(VMLifecycleService.canDelete(recoveryVM(state: "error")))
        // Without a record, `provisioning` has no owner and stays refused.
        #expect(!VMLifecycleService.canDelete(
            recoveryVM(state: "provisioning"), hasResumableProvision: false,
        ))
        // A resumable provision never unlocks any other state.
        #expect(!VMLifecycleService.canDelete(
            recoveryVM(state: "running"), hasResumableProvision: true,
        ))
        #expect(!VMLifecycleService.canDelete(
            recoveryVM(state: "starting"), hasResumableProvision: true,
        ))
    }

    @Test func `resetStaleVMStates leaves provisioning and deleting to their durable owners`() async throws {
        // `resetStaleVMStates` owns only the states a dead QEMU process left behind. Resetting
        // `provisioning` would advertise a half-written disk as startable, and resetting
        // `deleting` would resurrect a row mid-teardown — both are owned by durable operations
        // that `WorkloadOperationRecovery` resumes. This is the coverage gap that keeps the
        // ownership claim honest.
        let now = "2026-01-01T00:00:00Z"
        let cases: [(id: String, state: String, expected: String)] = [
            ("stale-running", "running", "stopped"),
            ("stale-starting", "starting", "stopped"),
            ("stale-stopping", "stopping", "stopped"),
            ("owned-provisioning", "provisioning", "provisioning"),
            ("owned-deleting", "deleting", "deleting"),
            ("already-stopped", "stopped", "stopped"),
        ]
        let pool = dbPool
        let dir = tmpDir
        try await pool.write { db in
            for testCase in cases {
                try Disk(
                    id: "disk-\(testCase.id)",
                    name: "boot",
                    path: dir.appendingPathComponent("\(testCase.id).qcow2").path,
                    sizeBytes: 1_024,
                    format: "qcow2",
                    vmId: testCase.id,
                    autoCreated: false,
                    status: "ready",
                    createdAt: now,
                ).insert(db)
                try VM(
                    id: testCase.id,
                    name: testCase.id,
                    vmType: "linux-arm64",
                    state: testCase.state,
                    cpuCount: 2,
                    memoryMb: 2_048,
                    bootDiskId: "disk-\(testCase.id)",
                    isoIds: nil,
                    networkId: nil,
                    cloudInitPath: nil,
                    description: nil,
                    bootOrder: nil,
                    displayResolution: nil,
                    additionalDiskIds: nil,
                    uefi: true,
                    tpmEnabled: false,
                    macAddress: nil,
                    sharedPaths: nil,
                    portForwards: nil,
                    usbDevices: nil,
                    autoCreated: false,
                    pendingChanges: false,
                    createdAt: now,
                    updatedAt: now,
                ).insert(db)
            }
        }

        let monitor = VMProcessMonitor(dbPool: pool)
        await monitor.resetStaleVMStates(excluding: [])
        for testCase in cases {
            let stored = try await pool.read { db in try VM.fetchOne(db, key: testCase.id) }
            #expect(stored?.state == testCase.expected, "\(testCase.id) was reset")
        }

        // A reconnected workload is left alone even in a state this method owns.
        try await pool.write { db in
            try db.execute(sql: "UPDATE vms SET state = 'running' WHERE id = 'stale-running'")
        }
        await monitor.resetStaleVMStates(excluding: ["stale-running"])
        #expect(
            try await pool.read { db in try VM.fetchOne(db, key: "stale-running") }?.state
                == "running",
        )
    }

    @Test func `a provisioning VM with no open provision record is released on startup`() async throws {
        // Nothing owns the claim: the create died between admitting the record and inserting the
        // row, or the record reached a terminal state. The row must not stay `provisioning`.
        let pool = dbPool
        let dir = tmpDir
        try await pool.write { db in
            try Disk(
                id: "disk-stranded-prov",
                name: "boot",
                path: dir.appendingPathComponent("stranded-prov.qcow2").path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-stranded-prov",
                autoCreated: false,
                status: "creating",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
            try recoveryVM(
                id: "vm-stranded-prov", state: "provisioning", bootDiskId: "disk-stranded-prov",
            ).insert(db)
        }
        // The record exists but is closed, so it cannot own the claim.
        let accepted = try await WorkloadOperationStore.accept(
            db: pool,
            idempotencyKey: "provision-dead",
            workloadID: "vm-stranded-prov",
            kind: WorkloadOperationKind.vmProvision,
            requestedGeneration: 1,
        )
        _ = try await WorkloadOperationStore.fail(
            db: pool,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: VMProvision.phaseCloning,
            recoveryOutcome: VMProvision.outcomeIncomplete,
            error: "clone failed",
        )
        await WorkloadOperationRecovery.resume(db: pool, dataDir: dir)
        let stored = try await pool.read { db in try VM.fetchOne(db, key: "vm-stranded-prov") }
        #expect(stored?.state == "error")
        // `error` is admitted by both start and delete, so the workload is usable again.
        #expect(try VMLifecycleService.canDelete(#require(stored)))
    }

    @Test func `a template placeholder provisioning with no provision record is not released`() async throws {
        // A template deploy parks its placeholder in `provisioning` while the image downloads.
        // The `pending_deploys` row is that window's owner, so recovery must leave it alone.
        let pool = dbPool
        let dir = tmpDir
        try await pool.write { db in
            try Disk(
                id: "disk-template-prov",
                name: "boot",
                path: dir.appendingPathComponent("template-prov.qcow2").path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: "vm-template-prov",
                autoCreated: false,
                status: "creating",
                createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
            try recoveryVM(
                id: "vm-template-prov", state: "provisioning", bootDiskId: "disk-template-prov",
            ).insert(db)
            try PendingDeploy(
                vmId: "vm-template-prov", imageId: "image-1", payload: "{}", createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        await WorkloadOperationRecovery.resume(db: pool, dataDir: dir)
        let stored = try await pool.read { db in try VM.fetchOne(db, key: "vm-template-prov") }
        #expect(stored?.state == "provisioning")
    }

    @Test func `canDelete admits a deleting workload that has a resumable delete`() {
        // A row left `deleting` by a crash is not a conflict: the durable record is the
        // resumption handle, and both a replay and a retry must be allowed through.
        #expect(VMLifecycleService.canDelete(
            recoveryApp(state: "deleting"), hasResumableDelete: true,
        ))
        #expect(VMLifecycleService.canDelete(
            recoveryVM(state: "deleting"), hasResumableDelete: true,
        ))
        // A `deleting` row still blocks every other transition.
        #expect(!VMLifecycleService.canDelete(
            recoveryApp(state: "deleting"), hasResumableDelete: false,
        ))
        #expect(!VMLifecycleService.canDelete(
            recoveryApp(state: "running"), hasResumableDelete: true,
        ))
    }

    @Test func `deleteVM removes a provisioning application and cancels create`() async throws {
        ComposeTestIsolation.installFailFast()
        let vm = recoveryApp(id: "whoami-del-pull", state: "provisioning")
        try await dbPool.write { db in try vm.insert(db) }
        let tasks = BackgroundTaskManager()
        await tasks.submit(ApplicationLifecycleService.taskID(forCreate: vm.id), kind: .appCreate) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return vm.id
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let compose = TeardownComposeStub()
        ComposeRuntime.runner = compose
        defer { ComposeTestIsolation.installFailFast() }
        let result = try await VMLifecycleService.deleteVM(
            id: vm.id,
            keepDisk: false,
            vmManager: VMManager(dbPool: dbPool),
            backgroundTasks: tasks,
            db: dbPool,
            dataDir: tmpDir,
        )
        #expect(result.vmName == vm.name)
        let create = await tasks.status(ApplicationLifecycleService.taskID(forCreate: vm.id))
        #expect(create?.status == .cancelled)

        for _ in 0 ..< 200 {
            if let event = await tasks.status(result.taskID),
               event.status == .completed || event.status == .failed || event.status == .cancelled {
                #expect(event.status == .completed)
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let stored = try await dbPool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(stored == nil)
        await tasks.cancelAll()
    }

    @Test func `deleteVM rejects a running application`() async throws {
        let vm = recoveryApp(id: "whoami-live-del", state: "running")
        try await dbPool.write { db in try vm.insert(db) }
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.deleteVM(
                id: vm.id,
                keepDisk: false,
                vmManager: VMManager(dbPool: self.dbPool),
                backgroundTasks: BackgroundTaskManager(),
                db: self.dbPool,
                dataDir: self.tmpDir,
            )
        }
        guard case let .conflict(message) = error else {
            Issue.record("expected conflict")
            return
        }
        #expect(message == "App must be stopped before deleting")
        let stored = try await dbPool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(stored?.state == "running")
    }
}

private func recoveryApp(id: String = "whoami-app", state: String) -> VM {
    VM(
        id: id,
        name: id,
        vmType: WorkloadSpec.applicationGuestType,
        state: state,
        cpuCount: 1,
        memoryMb: 256,
        bootDiskId: nil,
        kind: WorkloadSpec.kindApplication,
        composeYaml: "services: {}\n",
        composeProject: ComposeRuntime.composeProjectName(id: id),
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
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
    )
}

private func recoveryVM(id: String = "vm-box", state: String, bootDiskId: String = "disk-1") -> VM {
    VM(
        id: id,
        name: "box",
        vmType: "linux-arm64",
        state: state,
        cpuCount: 2,
        memoryMb: 2_048,
        bootDiskId: bootDiskId,
        isoIds: nil,
        networkId: nil,
        cloudInitPath: nil,
        description: nil,
        bootOrder: "cd",
        displayResolution: "1280x800",
        additionalDiskIds: nil,
        uefi: true,
        tpmEnabled: false,
        macAddress: nil,
        sharedPaths: nil,
        portForwards: nil,
        autoCreated: false,
        pendingChanges: false,
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
    )
}
