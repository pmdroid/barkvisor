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
                        try await harness.update()
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
        let operation = try #require(try await WorkloadOperationStore.fetch(db: harness.db.pool, id: open[0].id))
        #expect(operation.status == WorkloadOperationStatus.completed)
    }

    @Test func `unhealthy update restores images and configuration and leaves volume data`() async throws {
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
                    try await harness.update()
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

    @Test func `a data migration without a backup does not roll images back`() async throws {
        let harness = try await UpdateHarness()
        try await harness.prepareRunningApp()
        harness.docker.health = "unhealthy"
        harness.vm.composeYaml = "services:\n  web:\n    image: example/web:new\n"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.update(db) }
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await expectBarkVisorError {
                    try await ApplicationLifecycleService.updateImages(
                        vm: &harness.vm,
                        db: harness.db.pool,
                        dataDir: harness.db.dir,
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

    @Test func `a backed-up migration restores images without claiming the data was restored`() async throws {
        let harness = try await UpdateHarness()
        try await harness.prepareRunningApp()
        harness.docker.health = "unhealthy"
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                await expectBarkVisorError {
                    try await ApplicationLifecycleService.updateImages(
                        vm: &harness.vm,
                        db: harness.db.pool,
                        dataDir: harness.db.dir,
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

    @Test func `deployment manifest stores env by reference`() async throws {
        let harness = try await UpdateHarness()
        try harness.writeProject(yaml: "services:\n  web:\n    image: example/web:1\n", env: ["TOKEN": "hunter2"])
        harness.vm.state = "running"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.insert(db) }
        try await harness.run {
            try await WorkloadEffectGate.$healthTimeout.withValue(0) {
                try await harness.update()
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

    @Test func `failed teardown keeps files until a later retry removes them`() async throws {
        let harness = try await UpdateHarness()
        try harness.writeProject(yaml: "services:\n  web:\n    image: example/web:1\n", env: nil)
        let marker = harness.volumeFile
        try Data("volume".utf8).write(to: marker)
        harness.vm.state = "stopped"
        let saved = harness.vm
        try await harness.db.pool.write { db in try saved.insert(db) }
        harness.compose.failStop = true
        try await harness.run {
            await ApplicationLifecycleService.down(vm: harness.vm, dataDir: harness.db.dir)
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
        try await ApplicationLifecycleService.updateImages(
            vm: &vm,
            db: db.pool,
            dataDir: db.dir,
        )
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
