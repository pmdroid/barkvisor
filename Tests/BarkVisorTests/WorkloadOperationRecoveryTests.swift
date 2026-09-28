import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
struct WorkloadOperationRecoveryTests {
    @Test func `same idempotency key replays the durable result`() async throws {
        let db = try makeDB()
        var runs = 0
        let first = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "retry-1",
            workloadID: "vm-1",
            kind: WorkloadOperationKind.appUpdate,
            requestedGeneration: 3,
        )
        if first.started { runs += 1 }
        let lostReply = first.record.id
        let second = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "retry-1",
            workloadID: "vm-1",
            kind: WorkloadOperationKind.appUpdate,
            requestedGeneration: 3,
        )
        if second.started { runs += 1 }
        #expect(second.record.id == lostReply)
        #expect(!second.started)
        #expect(runs == 1)
        #expect(WorkloadOperationDedup.policy.contains("idempotency key"))
    }

    @Test func `an idempotency key cannot be reused for another workload`() async throws {
        let db = try makeDB()
        _ = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "shared-key",
            workloadID: "vm-1",
            kind: WorkloadOperationKind.appUpdate,
            requestedGeneration: 1,
        )
        await #expect(throws: BarkVisorError.self) {
            try await WorkloadOperationStore.accept(
                db: db.pool,
                idempotencyKey: "shared-key",
                workloadID: "vm-2",
                kind: WorkloadOperationKind.appUpdate,
                requestedGeneration: 1,
            )
        }
    }

    @Test func `a second key is rejected while an operation is open`() async throws {
        let db = try makeDB()
        _ = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "one",
            workloadID: "vm-1",
            kind: WorkloadOperationKind.appUpdate,
            requestedGeneration: 1,
        )
        await #expect(throws: BarkVisorError.self) {
            try await WorkloadOperationStore.accept(
                db: db.pool,
                idempotencyKey: "two",
                workloadID: "vm-1",
                kind: WorkloadOperationKind.appUpdate,
                requestedGeneration: 1,
            )
        }
    }

    @Test func `operation status survives a new database connection`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-ops-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try DatabasePool(path: url.path)
        try AppDatabase.makeMigrator().migrate(first)
        let accepted = try await WorkloadOperationStore.accept(
            db: first,
            idempotencyKey: "persist",
            workloadID: "vm-1",
            kind: WorkloadOperationKind.appUpdate,
            requestedGeneration: 4,
        )
        _ = try await WorkloadOperationStore.complete(
            db: first,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: "committed",
            recoveryOutcome: nil,
            resultPayload: "vm-1",
        )
        let restarted = try DatabasePool(path: url.path)
        let stored = try await WorkloadOperationStore.fetch(db: restarted, id: accepted.record.id)
        #expect(stored?.status == WorkloadOperationStatus.completed)
        #expect(stored?.resultPayload == "vm-1")
        #expect(stored?.requestedGeneration == 4)
        #expect(stored?.taskEvent().status == .completed)
    }

    @Test func `a replaced attempt ignores the previous callback`() async throws {
        let db = try makeDB()
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: nil,
            workloadID: "vm-1",
            kind: WorkloadOperationKind.appUpdate,
            requestedGeneration: 1,
        )
        let oldAttempt = accepted.record.attemptID
        #expect(try await WorkloadOperationStore.recordProgress(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: oldAttempt,
            progress: 0.4,
        ))
        let replaced = try await WorkloadOperationStore.beginReplacement(
            db: db.pool,
            operationID: accepted.record.id,
        )
        #expect(try await WorkloadOperationStore.attemptStatus(db: db.pool, attemptID: oldAttempt) == "superseded")
        #expect(try await WorkloadOperationStore.recordProgress(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: oldAttempt,
            progress: 0.9,
        ) == false)
        #expect(try await WorkloadOperationStore.setPhase(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: oldAttempt,
            phase: "committed",
        ) == false)
        #expect(try await WorkloadOperationStore.recordProgress(
            db: db.pool,
            operationID: replaced.id,
            attemptID: replaced.attemptID,
            progress: 0.5,
        ))
        let live = try await WorkloadOperationStore.fetch(db: db.pool, id: replaced.id)
        #expect(live?.progress == 0.5)
        #expect(live?.phase == "accepted")
        #expect(live?.status == WorkloadOperationStatus.recovering)
    }

    @Test func `daemon recovery adopts a live VM and does not change it`() async throws {
        let db = try makeDB()
        let vm = VM(
            id: "guest-1",
            name: "guest",
            vmType: "linux",
            state: "running",
            cpuCount: 1,
            memoryMb: 512,
            bootDiskId: nil,
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
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        let row = vm
        try await db.pool.write { db in try row.insert(db) }
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "vm-start",
            workloadID: vm.id,
            kind: WorkloadOperationKind.vmStart,
            requestedGeneration: vm.specGeneration,
        )
        _ = try await WorkloadOperationStore.setPhase(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: "before_spawn",
        )
        let vmID = vm.id
        try await VMAdoptionProbe.$alive.withValue({ id, _ in id == vmID }) {
            await WorkloadOperationRecovery.resume(db: db.pool, dataDir: db.dir)
        }
        let stored = try await db.pool.read { database in try VM.fetchOne(database, key: vmID) }
        let operation = try await WorkloadOperationStore.fetch(db: db.pool, id: accepted.record.id)
        #expect(stored?.state == "running")
        #expect(operation?.recoveryOutcome == ApplicationReadiness.outcomeAdopted)
        #expect(operation?.status == WorkloadOperationStatus.completed)
    }

    @Test func `missing QEMU is not replaced by recovery`() async throws {
        let db = try makeDB()
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "vm-start-dead",
            workloadID: "gone",
            kind: WorkloadOperationKind.vmStart,
            requestedGeneration: 1,
        )
        try await VMAdoptionProbe.$alive.withValue({ _, _ in false }) {
            await WorkloadOperationRecovery.resume(db: db.pool, dataDir: db.dir)
        }
        let operation = try await WorkloadOperationStore.fetch(db: db.pool, id: accepted.record.id)
        #expect(operation?.status == WorkloadOperationStatus.failed)
        #expect(operation?.recoveryOutcome == "spawn_not_observed")
        #expect(operation?.isRetryable == true)
    }

    @Test(
        .disabled("updateImages completes the pull without an operation-store checkpoint"),
        arguments: [
            "before_pull",
            "images_pulled",
            "before_compose_up",
            "compose_applied",
        ],
    )
    func `crash around pull and compose inspects state before repeating work`(_ point: String) async throws {
        let harness = try await UpdateHarness()
        try await harness.prepareRunningApp()
        let beforePull = harness.compose.pull
        let beforeUp = harness.compose.up
        try await harness.run {
            try await WorkloadEffectGate.$hook.withValue({ phase in
                if phase == point { throw WorkloadOperationInterrupted() }
            }) {
                try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                    await expectInterruption {
                        try await ApplicationDeployment.performImageUpdate(
                            vm: &harness.vm,
                            db: harness.db.pool,
                            dataDir: harness.db.dir,
                            operation: nil,
                            dataMigration: nil,
                            progress: nil,
                        )
                    }
                }
            }
        }
        let pulled = harness.compose.pull - beforePull
        let applied = harness.compose.up - beforeUp
        switch point {
        case "before_pull":
            #expect(pulled == 0)
            #expect(applied == 0)
        case "images_pulled":
            #expect(pulled == 1)
            #expect(applied == 0)
        case "before_compose_up":
            #expect(pulled == 1)
            #expect(applied == 0)
        case "compose_applied":
            #expect(pulled == 1)
            #expect(applied == 1)
        default:
            Issue.record("unexpected point")
        }
        let open = try await WorkloadOperationStore.openOperations(db: harness.db.pool)
        #expect(open.count == 1)
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
            }
        }
        let pulledAgain = harness.compose.pull - beforePull
        let appliedAgain = harness.compose.up - beforeUp
        switch point {
        case "before_pull":
            #expect(pulledAgain == 1)
            #expect(appliedAgain == 1)
        case "images_pulled", "before_compose_up":
            #expect(pulledAgain == 1)
            #expect(appliedAgain == 1)
        case "compose_applied":
            #expect(pulledAgain == 1)
            #expect(appliedAgain == 1)
        default:
            break
        }
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
            }
        }
        #expect(harness.compose.pull - beforePull == pulledAgain)
        #expect(harness.compose.up - beforeUp == appliedAgain)
        let accepted = try #require(open.first)
        let operation = try #require(try await WorkloadOperationStore.fetch(db: harness.db.pool, id: accepted.id))
        #expect(operation.status == WorkloadOperationStatus.completed)
    }

    @Test(.disabled("image update does not record a deployment operation"))
    func `unhealthy update restores images and configuration and leaves volume data`() async throws {
        let harness = try await UpdateHarness()
        try await harness.prepareRunningApp()
        let volume = harness.volumeFile
        try Data("keep".utf8).write(to: volume)
        harness.docker.health = "unhealthy"
        harness.vm.composeYaml = "services:\n  web:\n    image: example/web:new\n"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.update(db) }
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await expectBarkVisorError {
                    try await ApplicationDeployment.performImageUpdate(
                        vm: &harness.vm,
                        db: harness.db.pool,
                        dataDir: harness.db.dir,
                        operation: nil,
                        dataMigration: nil,
                        progress: nil,
                    )
                }
            }
        }
        let compose = try String(
            contentsOf: harness.project.appendingPathComponent("compose.yml"),
            encoding: .utf8,
        )
        #expect(compose.contains("example/web:1"))
        #expect(FileManager.default.fileExists(atPath: volume.path))
        let operations = try await harness.db.pool.read { db in try WorkloadOperationRecord.fetchAll(db) }
        let update = try #require(operations.first { $0.kind == WorkloadOperationKind.appUpdate })
        #expect(update.status == WorkloadOperationStatus.failed)
        #expect(update.recoveryOutcome == ApplicationReadiness.outcomeImagesRestored)
        #expect(update.dataRestored == 0)
        #expect(update.isRetryable)
        let revisions = try await harness.db.pool.read { db in try DeploymentRevisionRecord.fetchAll(db) }
        let current = try #require(revisions.first { $0.status == "current" })
        #expect(try current.manifest().composeYAML.contains("example/web:1"))
        #expect(revisions.contains { $0.status == "rolled_back" })
        #expect(!harness.compose.calls.contains { $0.contains("down") })
    }

    @Test(.disabled("image update does not record a deployment operation"))
    func `a data migration without a backup does not roll images back`() async throws {
        let harness = try await UpdateHarness()
        try await harness.prepareRunningApp()
        harness.docker.health = "unhealthy"
        harness.vm.composeYaml = "services:\n  web:\n    image: example/web:new\n"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.update(db) }
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await expectBarkVisorError {
                    try await ApplicationDeployment.performImageUpdate(
                        vm: &harness.vm,
                        db: harness.db.pool,
                        dataDir: harness.db.dir,
                        operation: nil,
                        dataMigration: DataMigrationDecision(backupReference: nil),
                        progress: nil,
                    )
                }
            }
        }
        let compose = try String(
            contentsOf: harness.project.appendingPathComponent("compose.yml"),
            encoding: .utf8,
        )
        #expect(compose.contains("example/web:new"))
        let update = try await harness.db.pool.read { db in
            try WorkloadOperationRecord.filter(Column("kind") == WorkloadOperationKind.appUpdate).fetchOne(db)
        }
        #expect(update?.recoveryOutcome == ApplicationReadiness.outcomeRollbackBlocked)
        #expect(update?.dataRestored == 0)
        #expect(update?.isRetryable == true)
        let preparing = try await harness.db.pool.read { db in
            try DeploymentRevisionRecord.filter(Column("status") == "failed").fetchOne(db)
        }
        #expect(preparing?.dataCompatibility == "migration")
        #expect(preparing?.backupDecision == "none")
    }

    @Test(.disabled("image update does not record a deployment operation"))
    func `a backed-up migration restores images without claiming the data was restored`() async throws {
        let harness = try await UpdateHarness()
        try await harness.prepareRunningApp()
        harness.docker.health = "unhealthy"
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await expectBarkVisorError {
                    try await ApplicationDeployment.performImageUpdate(
                        vm: &harness.vm,
                        db: harness.db.pool,
                        dataDir: harness.db.dir,
                        operation: nil,
                        dataMigration: DataMigrationDecision(backupReference: "snap-1"),
                        progress: nil,
                    )
                }
            }
        }
        let update = try await harness.db.pool.read { db in
            try WorkloadOperationRecord.filter(Column("kind") == WorkloadOperationKind.appUpdate).fetchOne(db)
        }
        #expect(update?.recoveryOutcome == ApplicationReadiness.outcomeImagesRestored)
        #expect(update?.dataRestored == 0)
        let preparing = try await harness.db.pool.read { db in
            try DeploymentRevisionRecord.filter(Column("status") == "rolled_back").fetchOne(db)
        }
        #expect(preparing?.backupDecision == "snapshot:snap-1")
    }

    @Test(.disabled("image update does not record a deployment operation"))
    func `deployment manifest stores env by reference`() async throws {
        let harness = try await UpdateHarness()
        try harness.writeProject(yaml: "services:\n  web:\n    image: example/web:1\n", env: ["TOKEN": "hunter2"])
        harness.vm.state = "running"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.insert(db) }
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                try await ApplicationDeployment.performImageUpdate(
                    vm: &harness.vm,
                    db: harness.db.pool,
                    dataDir: harness.db.dir,
                    operation: nil,
                    dataMigration: nil,
                    progress: nil,
                )
            }
        }
        let revisions = try await harness.db.pool.read { db in try DeploymentRevisionRecord.fetchAll(db) }
        #expect(!revisions.isEmpty)
        for revision in revisions {
            #expect(!revision.manifestJSON.contains("hunter2"))
            let manifest = try revision.manifest()
            if let envRef = manifest.envRef {
                let body = try String(
                    contentsOf: harness.project.appendingPathComponent(envRef),
                    encoding: .utf8,
                )
                #expect(body.contains("hunter2"))
            }
        }
        #expect(revisions.contains { (try? $0.manifest().envRef) != nil })
    }

    @Test(
        arguments: [
            VMDelete.phaseStopped,
            VMDelete.phaseResourcesReleased,
            VMDelete.phaseDisksRemoved,
            VMDelete.phaseRowDeleted,
        ],
    )
    func `a delete interrupted at any phase resolves within one restart`(_ point: String) async throws {
        let harness = try await DeleteHarness()

        // 1. The delete dies at `point`, exactly as a daemon crash would.
        try await WorkloadEffectGate.$hook.withValue({ phase in
            if phase == point { throw WorkloadOperationInterrupted() }
        }) {
            await expectInterruption {
                try await VMDelete.drive(
                    record: harness.operation, db: harness.db.pool, dataDir: harness.db.dir, report: nil,
                )
            }
        }
        let interrupted = try #require(
            try await WorkloadOperationStore.fetch(db: harness.db.pool, id: harness.operation.id),
        )
        // The record stays open so the next startup can resume it.
        #expect(interrupted.isOpen)
        #expect(interrupted.phase == point)
        // Until a disk is removed the workload row is still `deleting` — and never wedged,
        // because a durable record owns the claim. Removing the boot disk cascades the row
        // away, so from `disks_removed` on there is nothing left to strand.
        let stateAfterCrash = try await harness.state()
        let rowSurvives = try #require(VMDelete.phaseRank[point]) < VMDelete.phaseRank[VMDelete.phaseDisksRemoved]!
        #expect(stateAfterCrash == (rowSurvives ? "deleting" : nil))
        #expect(VMLifecycleService.canDelete(harness.vm, hasResumableDelete: true))

        // 2. One restart resumes and finishes it.
        await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        try await harness.assertFullyDeleted()

        // 3. Partial cleanup is idempotent: another restart changes nothing.
        await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        try await harness.assertFullyDeleted()
    }

    @Test func `a same-key replay during cleanup does not strand the row`() async throws {
        // Regression: a replay used to call `beginReplacement` unconditionally, so it stole the
        // attempt from the worker still running. That worker's next `setPhase` then failed and
        // the row was abandoned in `deleting` with no worker until the next restart.
        let harness = try await DeleteHarness()
        let tasks = BackgroundTaskManager()
        defer { Task { await tasks.cancelAll() } }
        let gate = AsyncStreamGate()
        let vmID = harness.vm.id
        let opID = harness.operation.id

        // The original request's worker, submitted the way `deleteVM` submits it, held at the
        // door so the replay lands while it still owns the attempt.
        await tasks.submit(opID, kind: .vmDelete) {
            await gate.waitForRelease()
            try await VMDelete.run(
                operationID: opID,
                attemptID: harness.operation.attemptID,
                vmManager: VMManager(dbPool: harness.db.pool),
                backgroundTasks: tasks,
                taskID: opID,
                db: harness.db.pool,
                dataDir: harness.db.dir,
            )
            return nil
        }
        for _ in 0 ..< 300 where await tasks.status(opID)?.status != .running {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await tasks.status(opID)?.status == .running)

        // The replay: same key, while the worker holds the record open.
        let replayed = try await VMLifecycleService.deleteVM(
            id: vmID, keepDisk: false, vmManager: VMManager(dbPool: harness.db.pool),
            backgroundTasks: tasks, db: harness.db.pool, dataDir: harness.db.dir,
            operationID: "delete-guest-box",
        )
        // It must replay the same record, not take a new attempt.
        #expect(replayed.taskID == opID)
        let afterReplay = try #require(try await WorkloadOperationStore.fetch(db: harness.db.pool, id: opID))
        #expect(afterReplay.attemptID == harness.operation.attemptID)
        #expect(afterReplay.isOpen)

        await gate.release()
        for _ in 0 ..< 300 {
            if await tasks.status(opID)?.status == .completed { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // The original worker finished its own record rather than being superseded.
        #expect(await tasks.status(opID)?.status == .completed)
        try await harness.assertFullyDeleted()
    }

    @Test func `a replayed delete hands back the durable record id as its task id`() async throws {
        // Regression: the response used to carry `vm-delete:<workloadID>`, a per-process handle.
        // `TaskController` falls back to `WorkloadOperationStore.fetch` by id, so after a
        // restart that handle 404s and the client loses status and progress.
        let harness = try await DeleteHarness()
        let tasks = BackgroundTaskManager()
        defer { Task { await tasks.cancelAll() } }
        let vmID = harness.vm.id
        let opID = harness.operation.id

        // The record already exists and is open, with no live in-memory worker: a replay
        // takes a fresh attempt and drives the cleanup.
        let replayed = try await VMLifecycleService.deleteVM(
            id: vmID, keepDisk: false, vmManager: VMManager(dbPool: harness.db.pool),
            backgroundTasks: tasks, db: harness.db.pool, dataDir: harness.db.dir,
            operationID: "delete-guest-box",
        )
        #expect(replayed.taskID == opID)
        // The task id the client holds is the one the durable store answers for, so status
        // survives the in-memory task going away.
        #expect(try await WorkloadOperationStore.fetch(db: harness.db.pool, id: replayed.taskID) != nil)
        for _ in 0 ..< 300 {
            if await tasks.status(replayed.taskID)?.status == .completed { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await harness.assertFullyDeleted()
    }

    @Test func `a replay of a completed delete does not reopen it or delete a reused id`() async throws {
        // Regression: a completed record skipped the live-task check but still went through
        // `beginReplacement`, which flipped it back to `recovering`. A workload that later
        // reused the id would then be deleted a second time by the replayed key.
        let db = try makeDB()
        let vmID = "vm-reused"
        let tasks = BackgroundTaskManager()
        defer { Task { await tasks.cancelAll() } }
        var original = recoveryGuest(id: vmID, state: "stopped")
        original.name = "first-life"
        let seed = original
        try await db.pool.write { db in try seed.insert(db) }
        let first = try await VMLifecycleService.deleteVM(
            id: vmID, keepDisk: false, vmManager: VMManager(dbPool: db.pool),
            backgroundTasks: tasks, db: db.pool, dataDir: db.dir,
            operationID: "reuse-key",
        )
        for _ in 0 ..< 300 {
            if await tasks.status(first.taskID)?.status == .completed { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let finished = try #require(try await WorkloadOperationStore.fetch(db: db.pool, id: first.taskID))
        #expect(finished.status == WorkloadOperationStatus.completed)

        // A new workload claims the id that the completed delete used to own.
        var reused = recoveryGuest(id: vmID, state: "stopped")
        reused.name = "second-life"
        let row = reused
        try await db.pool.write { db in try row.insert(db) }

        // The replayed key must return the stored result and leave the new row alone.
        let replayed = try await VMLifecycleService.deleteVM(
            id: vmID, keepDisk: false, vmManager: VMManager(dbPool: db.pool),
            backgroundTasks: tasks, db: db.pool, dataDir: db.dir,
            operationID: "reuse-key",
        )
        #expect(replayed.taskID == first.taskID)
        #expect(replayed.vmName == "first-life")
        let afterReplay = try #require(try await WorkloadOperationStore.fetch(db: db.pool, id: first.taskID))
        #expect(afterReplay.status == WorkloadOperationStatus.completed)
        #expect(afterReplay.finishedAt == finished.finishedAt)
        let survivor = try await db.pool.read { db in try VM.fetchOne(db, key: vmID) }
        #expect(survivor?.name == "second-life")
        #expect(survivor?.state == "stopped")
    }

    @Test func `concurrent same-key deletes do not strand the row`() async throws {
        // Regression: a replay arriving between the first request's accept and its submit saw
        // no live task, took a replacement attempt, then lost the duplicate `submit` race. The
        // stale worker failed its attempt check and the row stayed `deleting` with no worker.
        // The window is narrow, so this hammers it rather than hoping to land on it once.
        let harness = try await DeleteHarness()
        let vmID = harness.vm.id
        let db = harness.db.pool

        for round in 0 ..< 8 {
            let tasks = BackgroundTaskManager()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 4 {
                    group.addTask {
                        _ = try? await VMLifecycleService.deleteVM(
                            id: vmID, keepDisk: false, vmManager: VMManager(dbPool: db),
                            backgroundTasks: tasks, db: db, dataDir: harness.db.dir,
                            operationID: "delete-guest-box",
                        )
                    }
                }
            }
            // Every concurrent caller must agree the workload is gone, and no round may leave
            // an operation open with nothing to drive it.
            for _ in 0 ..< 300 {
                if try await db.read({ db in try VM.fetchOne(db, key: vmID) }) == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(
                try await db.read { db in try VM.fetchOne(db, key: vmID) } == nil,
                "round \(round) left the workload stranded",
            )
            let operations = try await db.read { db in
                try WorkloadOperationRecord.filter(Column("workloadID") == vmID).fetchAll(db)
            }
            #expect(operations.count == 1, "round \(round) started a second delete operation")
            for operation in operations {
                #expect(
                    operation.status != WorkloadOperationStatus.running,
                    "round \(round) left an operation open with no worker",
                )
            }
            if try await db.read({ db in try VM.fetchCount(db) }) == 0 { break }
        }
    }

    @Test func `a resuming delete repeats no finished phase`() async throws {
        let harness = try await DeleteHarness()
        try await WorkloadEffectGate.$hook.withValue({ phase in
            if phase == VMDelete.phaseResourcesReleased { throw WorkloadOperationInterrupted() }
        }) {
            await expectInterruption {
                try await VMDelete.drive(
                    record: harness.operation, db: harness.db.pool, dataDir: harness.db.dir, report: nil,
                )
            }
        }
        // `stopped` and `resources_released` are checkpointed, so the resumed run must not
        // redo them: the per-VM state directories and the auto-created network are already gone
        // and the boot disk is untouched.
        #expect(!FileManager.default.fileExists(atPath: harness.efiDir.path))
        #expect(!FileManager.default.fileExists(atPath: harness.tpmDir.path))
        #expect(!FileManager.default.fileExists(atPath: harness.cloudInitDir.path))
        #expect(try await harness.network() == nil)
        #expect(FileManager.default.fileExists(atPath: harness.bootDiskPath.path))
        #expect(try await harness.bootDiskRow() != nil)
        await WorkloadOperationRecovery.resume(db: harness.db.pool, dataDir: harness.db.dir)
        try await harness.assertFullyDeleted()
        // Repeating the release phase is a no-op, not a second adverse effect.
        try await VMLifecycleService.releaseDeleteResources(
            vm: harness.vm, db: harness.db.pool, dataDir: harness.db.dir,
        )
        #expect(try await harness.bootDiskRow() == nil)
    }

    @Test func `a vm delete operation flows through the task and retry surface`() async throws {
        let db = try makeDB()
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "delete-1",
            workloadID: "vm-del",
            kind: WorkloadOperationKind.vmDelete,
            requestedGeneration: 2,
            inputPayload: WorkloadDeleteIntent.encode(
                WorkloadDeleteIntent(keepDisk: true, vmName: "del"),
            ),
        )
        let event = accepted.record.taskEvent()
        #expect(event.kind == BackgroundTaskManager.TaskKind.vmDelete.rawValue)
        #expect(event.status == .running)
        #expect(accepted.record.deleteIntent == WorkloadDeleteIntent(keepDisk: true, vmName: "del"))
        #expect(accepted.record.isRetryable)
        #expect(accepted.record.isOpen)

        _ = try await WorkloadOperationStore.setPhase(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: VMDelete.phaseDisksRemoved,
            progress: 0.85,
        )
        let progressed = try #require(
            try await WorkloadOperationStore.fetch(db: db.pool, id: accepted.record.id),
        )
        #expect(progressed.taskEvent().progress == 0.85)
        #expect(progressed.phase == VMDelete.phaseDisksRemoved)

        _ = try await WorkloadOperationStore.complete(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: VMDelete.phaseRowDeleted,
            recoveryOutcome: VMDelete.outcomeDeleted,
            resultPayload: "vm-del",
        )
        let done = try #require(try await WorkloadOperationStore.fetch(db: db.pool, id: accepted.record.id))
        #expect(done.taskEvent().status == .completed)
        #expect(done.taskEvent().resultPayload == "vm-del")
        // Completion output stays in `resultPayload`; the intent stays in `inputPayload`.
        #expect(done.deleteIntent?.keepDisk == true)
    }

    @Test func `a fresh delete key is rejected while a delete is open`() async throws {
        let db = try makeDB()
        _ = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "delete-inflight",
            workloadID: "vm-del",
            kind: WorkloadOperationKind.vmDelete,
            requestedGeneration: 1,
        )
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await WorkloadOperationStore.accept(
                db: db.pool,
                idempotencyKey: "delete-fresh",
                workloadID: "vm-del",
                kind: WorkloadOperationKind.vmDelete,
                requestedGeneration: 1,
            )
        }
        guard case let .conflict(message) = error else {
            Issue.record("expected conflict")
            return
        }
        #expect(message.contains("vm.delete"))
        #expect(message.contains("delete-inflight") || message.contains("open vm.delete"))
    }

    @Test func `a deleting workload with no open delete is released on startup`() async throws {
        let db = try makeDB()
        let vm = recoveryGuest(id: "vm-stranded", state: "deleting")
        let row = vm
        try await db.pool.write { db in try row.insert(db) }
        // A delete that reached a terminal state cannot own the claim.
        let accepted = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "delete-dead",
            workloadID: vm.id,
            kind: WorkloadOperationKind.vmDelete,
            requestedGeneration: 1,
        )
        _ = try await WorkloadOperationStore.fail(
            db: db.pool,
            operationID: accepted.record.id,
            attemptID: accepted.record.attemptID,
            phase: VMDelete.phaseStopped,
            recoveryOutcome: VMDelete.outcomeIncomplete,
            error: "stop failed",
        )
        await WorkloadOperationRecovery.resume(db: db.pool, dataDir: db.dir)
        let stored = try await db.pool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(stored?.state == "error")
        #expect(try await db.pool.read { db in try VM.fetchCount(db) } == 1)
    }

    @Test func `a deleting workload with an open delete is not released`() async throws {
        let db = try makeDB()
        let vm = recoveryGuest(id: "vm-claimed", state: "deleting")
        try await db.pool.write { db in try vm.insert(db) }
        _ = try await WorkloadOperationStore.accept(
            db: db.pool,
            idempotencyKey: "delete-open",
            workloadID: vm.id,
            kind: WorkloadOperationKind.vmDelete,
            requestedGeneration: 1,
        )
        await WorkloadOperationRecovery.resume(db: db.pool, dataDir: db.dir)
        let stored = try await db.pool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(stored == nil)
    }

    @Test func `failed teardown reports the stop error`() async throws {
        let harness = try await UpdateHarness()
        try harness.writeProject(yaml: "services:\n  web:\n    image: example/web:1\n", env: nil)
        harness.vm.state = "stopped"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.insert(db) }
        harness.compose.failStop = true
        let accepted = try await WorkloadOperationStore.accept(
            db: harness.db.pool,
            idempotencyKey: nil,
            workloadID: harness.vm.id,
            kind: WorkloadOperationKind.appTeardown,
            requestedGeneration: harness.vm.specGeneration,
            projectPath: harness.project.path,
        )
        try await harness.run {
            await #expect(throws: BarkVisorError.self) {
                try await ApplicationDeployment.continueTeardown(
                    record: accepted.record,
                    vm: harness.vm,
                    db: harness.db.pool,
                    dataDir: harness.db.dir,
                    finishCleanup: true,
                )
            }
        }
        let failed = try await harness.db.pool.read { db in
            try WorkloadOperationRecord.fetchOne(db, key: accepted.record.id)
        }
        #expect(failed?.status == WorkloadOperationStatus.failed)
    }

    @Test func `failed teardown keeps files until a later retry removes them`() async throws {
        let harness = try await UpdateHarness()
        try harness.writeProject(yaml: "services:\n  web:\n    image: example/web:1\n", env: nil)
        let marker = harness.volumeFile
        try Data("volume".utf8).write(to: marker)
        harness.vm.state = "stopped"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.insert(db) }
        harness.compose.failStop = true
        let accepted = try await WorkloadOperationStore.accept(
            db: harness.db.pool,
            idempotencyKey: nil,
            workloadID: harness.vm.id,
            kind: WorkloadOperationKind.appTeardown,
            requestedGeneration: harness.vm.specGeneration,
            projectPath: harness.project.path,
        )
        try await harness.run {
            await #expect(throws: BarkVisorError.self) {
                try await ApplicationDeployment.continueTeardown(
                    record: accepted.record,
                    vm: harness.vm,
                    db: harness.db.pool,
                    dataDir: harness.db.dir,
                    finishCleanup: true,
                )
            }
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let failed = try await harness.db.pool.read { db in
            try WorkloadOperationRecord.filter(Column("kind") == WorkloadOperationKind.appTeardown).fetchOne(db)
        }
        #expect(failed?.status == WorkloadOperationStatus.failed)
        #expect(failed?.recoveryOutcome == ApplicationReadiness.outcomeCleanupIncomplete)
        #expect(failed?.isRetryable == true)
        #expect(harness.compose.down == 0)
        harness.compose.failStop = false
        harness.compose.stopped = true
        let operationID = try #require(failed).id
        try await harness.run {
            try await ApplicationDeployment.retry(
                db: harness.db.pool,
                operationID: operationID,
                dataDir: harness.db.dir,
            )
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(harness.compose.down == 0)
        try await harness.run {
            try await ApplicationDeployment.retry(
                db: harness.db.pool,
                operationID: operationID,
                dataDir: harness.db.dir,
            )
        }
        #expect(!FileManager.default.fileExists(atPath: harness.project.path))
        let downs = harness.compose.down
        try await harness.run {
            try await ApplicationDeployment.retry(
                db: harness.db.pool,
                operationID: operationID,
                dataDir: harness.db.dir,
            )
        }
        #expect(harness.compose.down == downs)
    }
}

private func expectInterruption(_ body: @Sendable () async throws -> Void) async {
    _ = await #expect(throws: WorkloadOperationInterrupted.self) {
        try await body()
    }
}

private func expectBarkVisorError(_ body: @Sendable () async throws -> Void) async {
    _ = await #expect(throws: BarkVisorError.self) {
        try await body()
    }
}

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

private final class UpdateHarness: @unchecked Sendable {
    let db: TempDB
    let compose = CountingCompose()
    let docker = CountingDocker()
    var vm: VM

    init() async throws {
        db = try makeDB()
        vm = VM(
            id: "app-web",
            name: "web",
            vmType: WorkloadSpec.applicationGuestType,
            state: "running",
            cpuCount: 1,
            memoryMb: 256,
            bootDiskId: nil,
            kind: WorkloadSpec.kindApplication,
            composeYaml: "services:\n  web:\n    image: example/web:1\n",
            composeProject: ComposeRuntime.composeProjectName(id: "app-web"),
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
        vm.catalogDigest = "sha256:new"
    }

    var project: URL {
        ComposeRuntime.projectDirectory(id: vm.id, dataDir: db.dir)
    }

    var volumeFile: URL {
        project.appendingPathComponent("volumes").appendingPathComponent("data.txt")
    }

    func writeProject(yaml: String, env: [String: String]?) throws {
        _ = try ComposeRuntime.writeProject(id: vm.id, yaml: yaml, env: env, dataDir: db.dir)
        try FileManager.default.createDirectory(
            at: volumeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
    }

    func prepareRunningApp() async throws {
        try writeProject(yaml: vm.composeYaml ?? "", env: nil)
        let row = vm
        try await db.pool.write { db in try row.insert(db) }
    }

    func run(_ body: @Sendable () async throws -> Void) async throws {
        let snap = DockerEngineSnapshot(
            os: "Linux",
            dockerPath: "/tmp/bv-test-docker",
            dockerVersion: "27.0.0",
            daemonRunning: true,
            composeVersion: "Docker Compose version v2.29.7",
            composeOK: true,
        )
        let inspect: @Sendable ([String]) throws -> Data = { _ in Data("[]".utf8) }
        try await DockerEngine.$snapshotOverride.withValue(snap) {
            try await ComposeRuntime.$runnerOverride.withValue(compose) {
                try await DockerCLI.$runnerOverride.withValue(docker) {
                    try await DockerInspect.$jsonOverride.withValue(inspect) {
                        try await body()
                    }
                }
            }
        }
    }

    func update() async throws {
        try await ApplicationDeployment.performImageUpdate(
            vm: &vm,
            db: db.pool,
            dataDir: db.dir,
            operation: nil,
            dataMigration: nil,
            progress: nil,
        )
    }
}

/// Lets a test hold a background worker at the door while it inspects mid-flight state.
private actor AsyncStreamGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private func recoveryGuest(id: String, state: String) -> VM {
    VM(
        id: id,
        name: id,
        vmType: "linux-arm64",
        state: state,
        cpuCount: 2,
        memoryMb: 2_048,
        bootDiskId: nil,
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
        autoCreated: false,
        pendingChanges: false,
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
    )
}

/// A plain workload whose delete touches every host resource: a managed boot disk, an
/// additional disk, per-VM state directories, and an auto-created network.
private final class DeleteHarness: @unchecked Sendable {
    let db: TempDB
    let operation: WorkloadOperationRecord
    let vm: VM
    let bootDiskPath: URL
    let cloudInitDir: URL
    let efiDir: URL
    let tpmDir: URL
    let networkID = "net-auto"
    static let networkID = "net-auto"
    static let diskID = "disk-boot"
    static let extraDiskID = "disk-extra"

    init() async throws {
        db = try makeDB()
        let disks = db.dir.appendingPathComponent("disks")
        try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: true)
        bootDiskPath = disks.appendingPathComponent("boot.qcow2")
        try Data("boot".utf8).write(to: bootDiskPath)
        let extraDisk = disks.appendingPathComponent("extra.qcow2")
        try Data("extra".utf8).write(to: extraDisk)
        cloudInitDir = db.dir.appendingPathComponent("cloud-init/guest-box")
        efiDir = db.dir.appendingPathComponent("efivars/guest-box")
        tpmDir = db.dir.appendingPathComponent("tpm/guest-box")
        for dir in [cloudInitDir, efiDir, tpmDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        vm = VM(
            id: "guest-box",
            name: "box",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: 2,
            memoryMb: 2_048,
            bootDiskId: Self.diskID,
            networkId: networkID,
            cloudInitPath: cloudInitDir.appendingPathComponent("seed").path,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: #"["\#(Self.extraDiskID)"]"#,
            uefi: true,
            tpmEnabled: true,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        let pool = db.pool
        try await Self.seed(
            pool: pool,
            disksDir: disks,
            vm: vm,
            bootPath: bootDiskPath,
            extraPath: extraDisk,
        )
        try await VMLifecycleService.markVMAsDeleting(id: vm.id, db: pool)
        let accepted = try await WorkloadOperationStore.accept(
            db: pool,
            idempotencyKey: "delete-guest-box",
            workloadID: vm.id,
            kind: WorkloadOperationKind.vmDelete,
            requestedGeneration: vm.specGeneration,
            inputPayload: WorkloadDeleteIntent.encode(
                WorkloadDeleteIntent(keepDisk: false, vmName: vm.name),
            ),
        )
        operation = accepted.record
    }

    private static func seed(
        pool: DatabasePool,
        disksDir: URL,
        vm: VM,
        bootPath: URL,
        extraPath: URL,
    ) async throws {
        try await pool.write { db in
            try AppSetting(key: DiskSettings.directoryKey, value: disksDir.path)
                .save(db, onConflict: .replace)
            // The boot disk is only unlinked when it sits in a managed storage root.
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: disksDir.path)
                .save(db, onConflict: .replace)
            try Network(
                id: networkID, name: "auto", mode: "nat", bridge: nil, macAddress: nil,
                dnsServer: nil, autoCreated: true, isDefault: false,
            ).insert(db)
            for (id, name, path) in [(diskID, "boot", bootPath), (extraDiskID, "extra", extraPath)] {
                try Disk(
                    id: id, name: name, path: path.path, sizeBytes: 1_024, format: "qcow2",
                    vmId: vm.id, autoCreated: false, status: "ready", createdAt: "2026-01-01T00:00:00Z",
                ).insert(db)
            }
            try vm.insert(db)
        }
    }

    func state() async throws -> String? {
        try await db.pool.read { db in try VM.fetchOne(db, key: vm.id)?.state }
    }

    func network() async throws -> Network? {
        try await db.pool.read { db in try Network.fetchOne(db, key: Self.networkID) }
    }

    func bootDiskRow() async throws -> Disk? {
        try await db.pool.read { db in try Disk.fetchOne(db, key: Self.diskID) }
    }

    func extraDiskRow() async throws -> Disk? {
        try await db.pool.read { db in try Disk.fetchOne(db, key: Self.extraDiskID) }
    }

    func assertFullyDeleted() async throws {
        let vmID = vm.id
        #expect(try await db.pool.read { db in try VM.fetchOne(db, key: vmID) } == nil)
        #expect(try await bootDiskRow() == nil)
        #expect(!FileManager.default.fileExists(atPath: bootDiskPath.path))
        #expect(try await extraDiskRow()?.vmId == nil)
        #expect(!FileManager.default.fileExists(atPath: cloudInitDir.path))
        #expect(!FileManager.default.fileExists(atPath: efiDir.path))
        #expect(!FileManager.default.fileExists(atPath: tpmDir.path))
        #expect(try await network() == nil)
        let finished = try #require(
            try await WorkloadOperationStore.fetch(db: db.pool, id: operation.id),
        )
        #expect(finished.status == WorkloadOperationStatus.completed)
        #expect(finished.phase == VMDelete.phaseRowDeleted)
        #expect(finished.recoveryOutcome == VMDelete.outcomeDeleted)
        #expect(finished.resultPayload == vmID)
    }
}

private final class CountingCompose: ComposeCommandRunning, @unchecked Sendable {
    var calls: [[String]] = []
    var pull = 0
    var up = 0
    var stop = 0
    var down = 0
    var stopped = false
    var failStop = false

    func run(
        arguments: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        calls.append(arguments)
        if arguments.contains("pull") { pull += 1 }
        if arguments.contains("up") { up += 1 }
        if arguments.contains("stop") {
            stop += 1
            if failStop {
                return CommandResult(exitCode: 1, stdout: Data(), stderr: Data("stop failed".utf8))
            }
            stopped = true
        }
        if arguments.contains("down") { down += 1 }
        if arguments.contains("-q") {
            return CommandResult(exitCode: 0, stdout: Data("cid1\n".utf8), stderr: Data())
        }
        if arguments.contains("ps") {
            let state = stopped ? "exited" : "running"
            return CommandResult(
                exitCode: 0,
                stdout: Data("{\"State\":\"\(state)\"}\n".utf8),
                stderr: Data(),
            )
        }
        return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private final class CountingDocker: DockerCommandRunning, @unchecked Sendable {
    var health: String?
    var digest = "sha256:old"

    func run(arguments: [String], timeout _: TimeInterval) throws -> CommandResult {
        if arguments.first == "inspect" {
            let image = arguments.dropFirst().contains { value in
                value.contains("/") || value.hasPrefix("sha256:")
            }
            if image {
                let json = """
                [{"Id":"sha256:config","RepoTags":["example/web:1"],"RepoDigests":["example/web@\(digest)"]}]
                """
                return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
            }
            let healthField = health.map { ",\"Health\":{\"Status\":\"\($0)\"}" } ?? ""
            let json = """
            [{"Id":"cid1","Config":{"Image":"example/web:1"},"State":{"Running":true,"Status":"running"\(healthField)}}]
            """
            return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
        if arguments.contains("manifest") {
            let json = """
            {"Descriptor":{"digest":"\(digest)"},"SchemaV2Manifest":{"config":{"digest":"sha256:config"}}}
            """
            return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
        return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}
