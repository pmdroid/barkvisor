import Foundation
import GRDB
import Yams

public struct DataMigrationDecision: Sendable, Equatable {
    public var backupReference: String?

    public init(backupReference: String?) {
        self.backupReference = backupReference
    }
}

public struct DeploymentServicePin: Codable, Equatable, Sendable {
    public var name: String
    public var image: String
    public var digest: String?

    public init(name: String, image: String, digest: String? = nil) {
        self.name = name
        self.image = image
        self.digest = digest
    }
}

public struct DeploymentManifest: Codable, Equatable, Sendable {
    public var composeYAML: String
    public var envKeys: [String]
    public var envRef: String?
    public var services: [DeploymentServicePin]
    public var gpuIDs: [String]
    public var publishedPorts: [PublishedPort]

    public init(
        composeYAML: String,
        envKeys: [String],
        envRef: String?,
        services: [DeploymentServicePin],
        gpuIDs: [String],
        publishedPorts: [PublishedPort],
    ) {
        self.composeYAML = composeYAML
        self.envKeys = envKeys
        self.envRef = envRef
        self.services = services
        self.gpuIDs = gpuIDs
        self.publishedPorts = publishedPorts
    }

    public var digests: [String] {
        services.compactMap(\.digest).filter { !$0.isEmpty }
    }
}

public struct DeploymentRevisionRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "deployment_revisions"

    public var id: String
    public var workloadID: String
    public var generation: Int
    public var status: String
    public var manifestJSON: String
    public var previousRevisionID: String?
    public var dataCompatibility: String
    public var backupDecision: String
    public var operationID: String?
    public var createdAt: String
    public var committedAt: String?

    public func manifest() throws -> DeploymentManifest {
        try JSONDecoder().decode(DeploymentManifest.self, from: Data(manifestJSON.utf8))
    }
}

public struct ApplicationServiceReadiness: Equatable, Sendable {
    public var name: String
    public var running: Bool
    public var healthStatus: String?
    public var exitCode: Int
    public var oneShotSucceeded: Bool

    public init(
        name: String,
        running: Bool,
        healthStatus: String?,
        exitCode: Int,
        oneShotSucceeded: Bool,
    ) {
        self.name = name
        self.running = running
        self.healthStatus = healthStatus
        self.exitCode = exitCode
        self.oneShotSucceeded = oneShotSucceeded
    }
}

public enum ApplicationReadiness {
    public static let outcomeImagesRestored = "images_and_config_restored"
    public static let outcomeRollbackBlocked = "rollback_blocked_data_migration"
    public static let outcomeRollbackFailed = "rollback_failed"
    public static let outcomeCleanupIncomplete = "cleanup_incomplete"
    public static let outcomeCleanupCompleted = "cleanup_completed"
    public static let outcomeAdopted = "adopted_running_process"

    public static func passed(_ services: [ApplicationServiceReadiness]) -> Bool {
        guard !services.isEmpty else { return false }
        return services.allSatisfy { service in
            if service.oneShotSucceeded { return true }
            if let healthStatus = service.healthStatus {
                return healthStatus == "healthy"
            }
            return service.running
        }
    }
}

public enum ApplicationServiceHealth {
    public static func observe(
        id: String,
        project: String,
        dataDir: URL,
    ) throws -> [ApplicationServiceReadiness] {
        let ids = try ComposeRuntime.containerIDs(id: id, project: project, dataDir: dataDir)
        if ids.isEmpty { return [] }
        let result = try DockerCLI.run(arguments: ["inspect"] + ids, timeout: 20)
        if !result.succeeded { return [] }
        return parse(result.stdoutString)
    }

    public static func parse(_ json: String) -> [ApplicationServiceReadiness] {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.map { row in
            let state = row["State"] as? [String: Any] ?? [:]
            let running = (state["Running"] as? Bool) ?? false
            let status = (state["Status"] as? String)?.lowercased()
            let exitCode = state["ExitCode"] as? Int ?? 0
            let health = (state["Health"] as? [String: Any])?["Status"] as? String
            let name = (row["Name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                ?? (row["Id"] as? String)
                ?? "service"
            let oneShot = !running && status == "exited" && exitCode == 0
            return ApplicationServiceReadiness(
                name: name,
                running: running,
                healthStatus: health,
                exitCode: exitCode,
                oneShotSucceeded: oneShot,
            )
        }
    }
}

struct DeploymentInputs {
    var render: ComposeRender
    var envKeys: [String]
    var gpuIDs: [String]
}

enum ApplicationDeployment {
    private static let phaseRank: [String: Int] = [
        "accepted": 0,
        "before_pull": 1,
        "images_pulled": 2,
        "before_compose_up": 3,
        "compose_applied": 4,
        "before_health": 5,
        "health_passed": 6,
        "before_commit": 7,
        "committed": 8,
        "before_rollback": 4,
        "rollback_applied": 9,
        "rollback_blocked": 9,
        "rollback_failed": 9,
    ]

    static func prepareInputs(
        vm: VM,
        db: DatabasePool,
        dataDir: URL,
    ) async throws -> DeploymentInputs {
        let gpuShare = try await ApplicationLifecycleService.shareAttach(for: vm, db: db)
        let catalog = await ApplicationLifecycleService.catalogEntry(for: vm, db: db)
        let render = try ApplicationLifecycleService.renderProject(
            vm: vm,
            dataDir: dataDir,
            gpuShare: gpuShare,
            catalog: catalog,
        )
        let env = ApplicationLifecycleService.decodeEnv(vm, dataDir: dataDir, catalog: catalog) ?? [:]
        return DeploymentInputs(
            render: render,
            envKeys: env.keys.sorted(),
            gpuIDs: (gpuShare.driDevices + gpuShare.nvidiaUUIDs).sorted(),
        )
    }

    static func recordCurrent(
        vm: VM,
        inputs: DeploymentInputs,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        let facts = (try? ApplicationImageFacts.running(
            id: vm.id,
            project: ApplicationLifecycleService.projectName(vm),
            dataDir: dataDir,
        )) ?? []
        _ = try await writeRevision(
            vm: vm,
            inputs: inputs,
            facts: facts,
            db: db,
            dataDir: dataDir,
            status: "current",
            previous: currentRevision(db: db, workloadID: vm.id),
            compatibility: "image_only",
            backupDecision: "not_required",
            operationID: nil,
            supersedePrevious: true,
        )
    }

    static func performImageUpdate(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        operation: WorkloadOperationRecord?,
        dataMigration: DataMigrationDecision?,
        progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        try await ApplicationLifecycleService.refuseDeleting(id: vm.id, db: db)
        try await ApplicationLifecycleService.requireRunning(id: vm.id, db: db)
        try DockerEngine.requireDeviceRuntime()
        let accepted: WorkloadOperationRecord
        if let operation {
            accepted = operation
        } else {
            let decision = try await WorkloadOperationStore.accept(
                db: db,
                idempotencyKey: nil,
                workloadID: vm.id,
                kind: WorkloadOperationKind.appUpdate,
                requestedGeneration: vm.specGeneration,
                projectPath: ComposeRuntime.projectDirectory(id: vm.id, dataDir: dataDir).path,
            )
            if !decision.started {
                vm = try await reload(id: vm.id, db: db)
                return
            }
            accepted = decision.record
        }
        do {
            try await runUpdate(
                vm: &vm,
                db: db,
                dataDir: dataDir,
                operation: accepted,
                dataMigration: dataMigration,
                progress: progress,
            )
        } catch is WorkloadOperationInterrupted {
            throw WorkloadOperationInterrupted()
        } catch let error as BarkVisorError {
            throw error
        } catch {
            _ = try? await WorkloadOperationStore.fail(
                db: db,
                operationID: accepted.id,
                attemptID: accepted.attemptID,
                phase: "failed",
                recoveryOutcome: ApplicationReadiness.outcomeRollbackFailed,
                error: error.localizedDescription,
            )
            throw error
        }
    }

    static func recoverOpen(db: DatabasePool, dataDir: URL = Config.dataDir) async {
        let open: [WorkloadOperationRecord]
        do {
            open = try await WorkloadOperationStore.openOperations(db: db)
        } catch {
            Log.vm.warning("Operation recovery list failed: \(error.localizedDescription)")
            return
        }
        for record in open {
            do {
                let replaced = try await WorkloadOperationStore.beginReplacement(db: db, operationID: record.id)
                try await recover(record: replaced, db: db, dataDir: dataDir)
            } catch is WorkloadOperationInterrupted {
                continue
            } catch {
                Log.vm.warning(
                    "Operation \(record.id) recovery failed: \(error.localizedDescription)",
                    vm: record.workloadID,
                )
            }
        }
    }

    static func retry(
        db: DatabasePool,
        operationID: String,
        dataDir: URL = Config.dataDir,
    ) async throws {
        let replaced = try await WorkloadOperationStore.beginReplacement(db: db, operationID: operationID)
        try await recover(record: replaced, db: db, dataDir: dataDir)
    }

    private static func recover(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        switch record.kind {
        case WorkloadOperationKind.appUpdate:
            guard var vm = try await db.read({ db in try VM.fetchOne(db, key: record.workloadID) }) else {
                _ = try await WorkloadOperationStore.fail(
                    db: db,
                    operationID: record.id,
                    attemptID: record.attemptID,
                    phase: record.phase,
                    recoveryOutcome: "workload_missing",
                    error: "Workload \(record.workloadID) not found",
                )
                return
            }
            do {
                try await runUpdate(
                    vm: &vm,
                    db: db,
                    dataDir: dataDir,
                    operation: record,
                    dataMigration: nil,
                    progress: nil,
                )
            } catch is WorkloadOperationInterrupted {
                throw WorkloadOperationInterrupted()
            } catch {
                _ = try? await WorkloadOperationStore.fail(
                    db: db,
                    operationID: record.id,
                    attemptID: record.attemptID,
                    phase: "failed",
                    recoveryOutcome: ApplicationReadiness.outcomeRollbackFailed,
                    error: error.localizedDescription,
                )
                throw error
            }
        case WorkloadOperationKind.appTeardown:
            let vm = try await db.read { db in try VM.fetchOne(db, key: record.workloadID) }
            let phase = record.phase
            let finish = phase == "containers_stopped" || phase == "before_file_cleanup"
                || phase == "files_removed"
            try await continueTeardown(
                record: record,
                vm: vm,
                db: db,
                dataDir: dataDir,
                finishCleanup: finish,
            )
        case WorkloadOperationKind.vmStart:
            try await adoptVM(record: record, db: db, dataDir: dataDir)
        default:
            if record.kind.hasPrefix("vm.") {
                try await adoptVM(record: record, db: db, dataDir: dataDir)
            }
        }
    }

    private static func runUpdate(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        operation: WorkloadOperationRecord,
        dataMigration: DataMigrationDecision?,
        progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        let phase = try await currentPhase(operation: operation, db: db)
        if phase == "before_rollback" || phase == "rollback_applied" || phase == "rollback_blocked"
            || phase == "rollback_failed" {
            try await finishRollback(
                vm: &vm,
                db: db,
                dataDir: dataDir,
                operation: operation,
            )
            return
        }
        if rank(phase) >= rank("committed") {
            _ = try await WorkloadOperationStore.complete(
                db: db,
                operationID: operation.id,
                attemptID: operation.attemptID,
                phase: "committed",
                recoveryOutcome: nil,
                resultPayload: vm.id,
            )
            return
        }

        try await ensureCurrent(vm: vm, db: db, dataDir: dataDir)
        let inputs = try await prepareInputs(vm: vm, db: db, dataDir: dataDir)
        try await ApplicationLifecycleService.applyPublishedPorts(
            inputs.render.publishedPorts,
            to: &vm,
            db: db,
        )
        let decision = compatibility(dataMigration)
        let preparing = try await preparingRevision(
            vm: vm,
            inputs: inputs,
            db: db,
            dataDir: dataDir,
            operation: operation,
            compatibility: decision.compatibility,
            backupDecision: decision.backup,
        )
        let project = ApplicationLifecycleService.projectName(vm)
        try await report(operation: operation, db: db, progress: 0.2, callback: progress)

        if try await rank(currentPhase(operation: operation, db: db)) < rank("images_pulled") {
            let phaseNow = try await currentPhase(operation: operation, db: db)
            let targetDigests = try preparing.manifest().digests
            let alreadyPulled = phaseNow != "accepted" && digestsMatch(
                target: targetDigests,
                id: vm.id,
                project: project,
                dataDir: dataDir,
            )
            if !alreadyPulled {
                try await checkpoint(operation: operation, db: db, phase: "before_pull", progress: 0.25)
                try ComposeRuntime.pull(id: vm.id, project: project, dataDir: dataDir)
            }
            try await stampDigests(revision: preparing, vm: vm, db: db, dataDir: dataDir)
            try await checkpoint(operation: operation, db: db, phase: "images_pulled", progress: 0.6)
        }
        try await report(operation: operation, db: db, progress: 0.6, callback: progress)

        if try await rank(currentPhase(operation: operation, db: db)) < rank("compose_applied") {
            try await checkpoint(operation: operation, db: db, phase: "before_compose_up", progress: 0.7)
            try await ApplicationLifecycleService.refuseDeleting(id: vm.id, db: db)
            try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
            try await checkpoint(operation: operation, db: db, phase: "compose_applied", progress: 0.85)
        }

        try ApplicationLifecycleService.verifyInspectedBinds(
            containerNames: inputs.render.containerNames,
            bindHost: inputs.render.bindHost,
            expected: inputs.render.publishedPorts,
        )
        try await checkpoint(operation: operation, db: db, phase: "before_health", progress: 0.9)
        let healthy = await waitUntilReady(id: vm.id, project: project, dataDir: dataDir)
        if !healthy {
            try await rollback(
                vm: &vm,
                db: db,
                dataDir: dataDir,
                operation: operation,
                preparing: reloadRevision(id: preparing.id, db: db),
            )
            return
        }
        try await checkpoint(operation: operation, db: db, phase: "health_passed", progress: 0.95)
        try await checkpoint(operation: operation, db: db, phase: "before_commit", progress: 0.97)
        try await ApplicationLifecycleService.persistRuntime(
            vm: &vm,
            namedVolumes: inputs.render.namedVolumes,
            db: db,
            dataDir: dataDir,
        )
        try await ApplicationLifecycleService.refreshCatalogDigest(vm: &vm, db: db, dataDir: dataDir)
        try await commitRevision(id: preparing.id, workloadID: vm.id, db: db)
        try await ApplicationLifecycleService.setState(&vm, state: "running", error: nil, db: db)
        await ApplicationLifecycleService.noteAppRunning(id: vm.id, project: project)
        try await report(operation: operation, db: db, progress: 1, callback: progress)
        guard try await WorkloadOperationStore.complete(
            db: db,
            operationID: operation.id,
            attemptID: operation.attemptID,
            phase: "committed",
            recoveryOutcome: nil,
            resultPayload: vm.id,
        ) else {
            throw WorkloadOperationInterrupted()
        }
    }

    private static func rollback(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        operation: WorkloadOperationRecord,
        preparing: DeploymentRevisionRecord,
    ) async throws {
        let allowed = rollbackAllowed(
            compatibility: preparing.dataCompatibility,
            backupDecision: preparing.backupDecision,
        )
        guard allowed else {
            try await markRevision(id: preparing.id, status: "failed", db: db, committed: false)
            _ = try await WorkloadOperationStore.fail(
                db: db,
                operationID: operation.id,
                attemptID: operation.attemptID,
                phase: "rollback_blocked",
                recoveryOutcome: ApplicationReadiness.outcomeRollbackBlocked,
                error: "Health checks failed. Automatic image rollback needs an explicit data backup decision.",
            )
            try await ApplicationLifecycleService.setState(
                &vm,
                state: "error",
                error: ApplicationReadiness.outcomeRollbackBlocked,
                db: db,
            )
            throw BarkVisorError.updateFailed(ApplicationReadiness.outcomeRollbackBlocked)
        }
        try await checkpoint(operation: operation, db: db, phase: "before_rollback", progress: operation.progress)
        do {
            try await restorePrevious(vm: vm, db: db, dataDir: dataDir)
            try WorkloadEffectGate.pass("rollback_applied")
            try await markRevision(id: preparing.id, status: "rolled_back", db: db, committed: false)
            _ = try await WorkloadOperationStore.fail(
                db: db,
                operationID: operation.id,
                attemptID: operation.attemptID,
                phase: "rollback_applied",
                recoveryOutcome: ApplicationReadiness.outcomeImagesRestored,
                error: "Health checks failed. Previous images and configuration were restored. Volume data was left in place.",
            )
            try await ApplicationLifecycleService.setState(&vm, state: "running", error: nil, db: db)
        } catch is WorkloadOperationInterrupted {
            throw WorkloadOperationInterrupted()
        } catch {
            _ = try await WorkloadOperationStore.fail(
                db: db,
                operationID: operation.id,
                attemptID: operation.attemptID,
                phase: "rollback_failed",
                recoveryOutcome: ApplicationReadiness.outcomeRollbackFailed,
                error: error.localizedDescription,
            )
            throw error
        }
        throw BarkVisorError.updateFailed(ApplicationReadiness.outcomeImagesRestored)
    }

    private static func finishRollback(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        operation: WorkloadOperationRecord,
    ) async throws {
        let phase = try await currentPhase(operation: operation, db: db)
        if phase == "rollback_applied" || phase == "rollback_blocked" || phase == "rollback_failed" {
            return
        }
        let preparing = try await preparingRevisionRow(db: db, workloadID: vm.id)
        if let preparing,
           !rollbackAllowed(compatibility: preparing.dataCompatibility, backupDecision: preparing.backupDecision) {
            _ = try await WorkloadOperationStore.fail(
                db: db,
                operationID: operation.id,
                attemptID: operation.attemptID,
                phase: "rollback_blocked",
                recoveryOutcome: ApplicationReadiness.outcomeRollbackBlocked,
                error: ApplicationReadiness.outcomeRollbackBlocked,
            )
            return
        }
        let project = ApplicationLifecycleService.projectName(vm)
        let previous = try await currentRevision(db: db, workloadID: vm.id)
        let previousDigests = (try? previous?.manifest().digests) ?? []
        if !digestsMatch(target: previousDigests, id: vm.id, project: project, dataDir: dataDir) {
            try await restorePrevious(vm: vm, db: db, dataDir: dataDir)
        }
        if let preparing {
            try await markRevision(id: preparing.id, status: "rolled_back", db: db, committed: false)
        }
        _ = try await WorkloadOperationStore.fail(
            db: db,
            operationID: operation.id,
            attemptID: operation.attemptID,
            phase: "rollback_applied",
            recoveryOutcome: ApplicationReadiness.outcomeImagesRestored,
            error: "Previous images and configuration were restored. Volume data was left in place.",
        )
    }

    static func restorePrevious(vm: VM, db: DatabasePool, dataDir: URL) async throws {
        guard let previous = try await currentRevision(db: db, workloadID: vm.id) else {
            throw BarkVisorError.internalError("no current deployment revision to restore")
        }
        let manifest = try previous.manifest()
        let project = ApplicationLifecycleService.projectName(vm)
        let dir = ComposeRuntime.projectDirectory(id: vm.id, dataDir: dataDir)
        let composeURL = dir.appendingPathComponent("compose.yml")
        let onDisk = try? String(contentsOf: composeURL, encoding: .utf8)
        let filesMatch = onDisk == manifest.composeYAML
        if !filesMatch {
            let env = readEnvFile(root: dir, ref: manifest.envRef)
            _ = try ComposeRuntime.writeProject(id: vm.id, yaml: manifest.composeYAML, env: env, dataDir: dataDir)
        }
        if filesMatch, digestsMatch(target: manifest.digests, id: vm.id, project: project, dataDir: dataDir) {
            return
        }
        try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
    }

    static func continueTeardown(
        record: WorkloadOperationRecord,
        vm: VM?,
        db: DatabasePool,
        dataDir: URL,
        finishCleanup: Bool,
    ) async throws {
        let workloadID = record.workloadID
        let project = vm.map(ApplicationLifecycleService.projectName)
            ?? ComposeRuntime.composeProjectName(id: workloadID)
        var phase = try await currentPhase(operation: record, db: db)
        if phase == "files_removed" || phase == "committed" {
            _ = try await WorkloadOperationStore.complete(
                db: db,
                operationID: record.id,
                attemptID: record.attemptID,
                phase: "files_removed",
                recoveryOutcome: ApplicationReadiness.outcomeCleanupCompleted,
                resultPayload: workloadID,
            )
            return
        }
        let stopped = containersStopped(id: workloadID, project: project, dataDir: dataDir)
        if phase == "accepted" || phase == "before_container_stop" || !stopped {
            if !stopped {
                try await checkpoint(operation: record, db: db, phase: "before_container_stop")
                do {
                    try ComposeRuntime.stop(id: workloadID, project: project, dataDir: dataDir)
                } catch {
                    _ = try? await WorkloadOperationStore.fail(
                        db: db,
                        operationID: record.id,
                        attemptID: record.attemptID,
                        phase: "before_container_stop",
                        recoveryOutcome: ApplicationReadiness.outcomeCleanupIncomplete,
                        error: error.localizedDescription,
                    )
                    throw error
                }
                try await checkpoint(operation: record, db: db, phase: "containers_stopped")
                if !finishCleanup { return }
            } else {
                try await checkpoint(operation: record, db: db, phase: "containers_stopped")
                if !finishCleanup { return }
            }
            phase = "containers_stopped"
        }
        guard containersStopped(id: workloadID, project: project, dataDir: dataDir) else {
            _ = try await WorkloadOperationStore.fail(
                db: db,
                operationID: record.id,
                attemptID: record.attemptID,
                phase: "containers_stopped",
                recoveryOutcome: ApplicationReadiness.outcomeCleanupIncomplete,
                error: "containers still running",
            )
            return
        }
        try await checkpoint(operation: record, db: db, phase: "before_file_cleanup")
        try ComposeRuntime.down(id: workloadID, project: project, dataDir: dataDir)
        ComposeRuntime.removeProject(id: workloadID, dataDir: dataDir)
        guard try await WorkloadOperationStore.setPhase(
            db: db,
            operationID: record.id,
            attemptID: record.attemptID,
            phase: "files_removed",
        ) else {
            throw WorkloadOperationInterrupted()
        }
        try WorkloadEffectGate.pass("files_removed")
        guard try await WorkloadOperationStore.complete(
            db: db,
            operationID: record.id,
            attemptID: record.attemptID,
            phase: "files_removed",
            recoveryOutcome: ApplicationReadiness.outcomeCleanupCompleted,
            resultPayload: workloadID,
        ) else {
            throw WorkloadOperationInterrupted()
        }
    }

    private static func adoptVM(
        record: WorkloadOperationRecord,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        let alive = VMAdoptionProbe.alive?(record.workloadID, dataDir)
            ?? qemuAlive(vmID: record.workloadID, dataDir: dataDir)
        if alive {
            guard try await WorkloadOperationStore.complete(
                db: db,
                operationID: record.id,
                attemptID: record.attemptID,
                phase: "adopted",
                recoveryOutcome: ApplicationReadiness.outcomeAdopted,
                resultPayload: record.workloadID,
            ) else {
                throw WorkloadOperationInterrupted()
            }
            return
        }
        _ = try await WorkloadOperationStore.fail(
            db: db,
            operationID: record.id,
            attemptID: record.attemptID,
            phase: record.phase,
            recoveryOutcome: "spawn_not_observed",
            error: "QEMU process was not alive; recovery did not start a replacement",
        )
    }

    static func qemuAlive(vmID: String, dataDir: URL) -> Bool {
        let url = dataDir.appendingPathComponent("pids", isDirectory: true)
            .appendingPathComponent("\(vmID).pid")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = VMPidFile.parse(text)?.qemuPid
        else { return false }
        guard kill(pid, 0) == 0 else { return false }
        guard let argv = PlatformProcess.arguments(pid: pid) else { return false }
        guard let parsed = QEMUArgv(arguments: argv) else { return false }
        if let uuid = parsed.uuid, uuid != vmID { return false }
        return true
    }

    private static func containersStopped(id: String, project: String, dataDir: URL) -> Bool {
        guard let state = try? ComposeRuntime.psState(id: id, project: project, dataDir: dataDir) else {
            return false
        }
        return state != "running"
    }

    private static func ensureCurrent(vm: VM, db: DatabasePool, dataDir: URL) async throws {
        if try await currentRevision(db: db, workloadID: vm.id) != nil { return }
        let dir = ComposeRuntime.projectDirectory(id: vm.id, dataDir: dataDir)
        let yaml = (try? String(contentsOf: dir.appendingPathComponent("compose.yml"), encoding: .utf8))
            ?? vm.composeYaml
            ?? ""
        let env = ComposeRuntime.readEnv(id: vm.id, dataDir: dataDir) ?? [:]
        let facts = (try? ApplicationImageFacts.running(
            id: vm.id,
            project: ApplicationLifecycleService.projectName(vm),
            dataDir: dataDir,
        )) ?? []
        let inputs = DeploymentInputs(
            render: ComposeRender(
                yaml: yaml,
                publishedPorts: [],
                namedVolumes: [],
            ),
            envKeys: env.keys.sorted(),
            gpuIDs: [],
        )
        _ = try await writeRevision(
            vm: vm,
            inputs: inputs,
            facts: facts,
            db: db,
            dataDir: dataDir,
            status: "current",
            previous: nil,
            compatibility: "image_only",
            backupDecision: "not_required",
            operationID: nil,
            supersedePrevious: false,
        )
    }

    private static func preparingRevision(
        vm: VM,
        inputs: DeploymentInputs,
        db: DatabasePool,
        dataDir: URL,
        operation: WorkloadOperationRecord,
        compatibility: String,
        backupDecision: String,
    ) async throws -> DeploymentRevisionRecord {
        if let existing = try await preparingRevisionRow(db: db, workloadID: vm.id) {
            return existing
        }
        let previous = try await currentRevision(db: db, workloadID: vm.id)
        let desired = desiredDigests(vm: vm, facts: [])
        var facts = desired.map { ComposeImageFact(image: $0.image, digest: $0.digest) }
        if facts.isEmpty {
            facts = (try? ApplicationImageFacts.running(
                id: vm.id,
                project: ApplicationLifecycleService.projectName(vm),
                dataDir: dataDir,
            )) ?? []
        }
        return try await writeRevision(
            vm: vm,
            inputs: inputs,
            facts: facts,
            db: db,
            dataDir: dataDir,
            status: "preparing",
            previous: previous,
            compatibility: compatibility,
            backupDecision: backupDecision,
            operationID: operation.id,
            supersedePrevious: false,
        )
    }

    private static func writeRevision(
        vm: VM,
        inputs: DeploymentInputs,
        facts: [ComposeImageFact],
        db: DatabasePool,
        dataDir: URL,
        status: String,
        previous: DeploymentRevisionRecord?,
        compatibility: String,
        backupDecision: String,
        operationID: String?,
        supersedePrevious: Bool,
    ) async throws -> DeploymentRevisionRecord {
        let id = UUID().uuidString
        let dir = ComposeRuntime.projectDirectory(id: vm.id, dataDir: dataDir)
        let envRef = copyEnv(root: dir, revisionID: id)
        let pins = servicePins(yaml: inputs.render.yaml, facts: facts)
        let manifest = DeploymentManifest(
            composeYAML: inputs.render.yaml,
            envKeys: inputs.envKeys,
            envRef: envRef,
            services: pins,
            gpuIDs: inputs.gpuIDs,
            publishedPorts: inputs.render.publishedPorts,
        )
        let encoded = try JSONEncoder().encode(manifest)
        let now = iso8601.string(from: Date())
        let record = DeploymentRevisionRecord(
            id: id,
            workloadID: vm.id,
            generation: vm.specGeneration,
            status: status,
            manifestJSON: String(decoding: encoded, as: UTF8.self),
            previousRevisionID: previous?.id,
            dataCompatibility: compatibility,
            backupDecision: backupDecision,
            operationID: operationID,
            createdAt: now,
            committedAt: status == "current" ? now : nil,
        )
        try await db.write { db in
            if supersedePrevious, var previous {
                previous.status = "superseded"
                try previous.update(db)
            }
            try record.insert(db)
        }
        return record
    }

    private static func stampDigests(
        revision: DeploymentRevisionRecord,
        vm: VM,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        let facts = (try? ApplicationImageFacts.running(
            id: vm.id,
            project: ApplicationLifecycleService.projectName(vm),
            dataDir: dataDir,
        )) ?? []
        var manifest = try revision.manifest()
        manifest.services = manifest.services.map { pin in
            var copy = pin
            if copy.digest == nil {
                copy.digest = facts.first {
                    $0.image == copy.image || copy.image.hasPrefix($0.image) || $0.image.hasPrefix(copy.image)
                }?.digest ?? vm.catalogDigest
            }
            return copy
        }
        let encoded = try JSONEncoder().encode(manifest)
        try await db.write { db in
            guard var row = try DeploymentRevisionRecord.fetchOne(db, key: revision.id) else { return }
            row.manifestJSON = String(decoding: encoded, as: UTF8.self)
            try row.update(db)
        }
    }

    private static func commitRevision(id: String, workloadID: String, db: DatabasePool) async throws {
        let now = iso8601.string(from: Date())
        try await db.write { db in
            let currents = try DeploymentRevisionRecord
                .filter(Column("workloadID") == workloadID && Column("status") == "current")
                .fetchAll(db)
            for var current in currents where current.id != id {
                current.status = "superseded"
                try current.update(db)
            }
            guard var row = try DeploymentRevisionRecord.fetchOne(db, key: id) else { return }
            row.status = "current"
            row.committedAt = now
            try row.update(db)
        }
    }

    private static func markRevision(
        id: String,
        status: String,
        db: DatabasePool,
        committed: Bool,
    ) async throws {
        try await db.write { db in
            guard var row = try DeploymentRevisionRecord.fetchOne(db, key: id) else { return }
            row.status = status
            if committed {
                row.committedAt = iso8601.string(from: Date())
            }
            try row.update(db)
        }
    }

    static func currentRevision(
        db: DatabasePool,
        workloadID: String,
    ) async throws -> DeploymentRevisionRecord? {
        try await db.read { db in
            try DeploymentRevisionRecord
                .filter(Column("workloadID") == workloadID && Column("status") == "current")
                .fetchOne(db)
        }
    }

    private static func preparingRevisionRow(
        db: DatabasePool,
        workloadID: String,
    ) async throws -> DeploymentRevisionRecord? {
        try await db.read { db in
            try DeploymentRevisionRecord
                .filter(Column("workloadID") == workloadID && Column("status") == "preparing")
                .fetchOne(db)
        }
    }

    private static func reloadRevision(id: String, db: DatabasePool) async throws -> DeploymentRevisionRecord {
        guard let row = try await db.read({ db in try DeploymentRevisionRecord.fetchOne(db, key: id) }) else {
            throw BarkVisorError.notFound("deployment revision \(id) not found")
        }
        return row
    }

    private static func compatibility(
        _ decision: DataMigrationDecision?,
    ) -> (compatibility: String, backup: String) {
        guard let decision else {
            return ("image_only", "not_required")
        }
        if let reference = decision.backupReference, !reference.isEmpty {
            return ("migration", "snapshot:\(reference)")
        }
        return ("migration", "none")
    }

    private static func rollbackAllowed(compatibility: String, backupDecision: String) -> Bool {
        if compatibility == "image_only" { return true }
        if compatibility == "migration", backupDecision.hasPrefix("snapshot:") { return true }
        return false
    }

    private static func desiredDigests(vm: VM, facts: [ComposeImageFact]) -> [DeploymentServicePin] {
        let yaml = vm.composeYaml ?? ""
        var pins = servicePins(yaml: yaml, facts: facts)
        if let catalog = vm.catalogDigest, !catalog.isEmpty {
            pins = pins.map { pin in
                var copy = pin
                if copy.digest == nil { copy.digest = catalog }
                return copy
            }
        }
        return pins
    }

    private static func servicePins(yaml: String, facts: [ComposeImageFact]) -> [DeploymentServicePin] {
        guard let loaded = try? Yams.load(yaml: yaml) as? [String: Any],
              let services = loaded["services"] as? [String: Any]
        else { return [] }
        return services.keys.sorted().compactMap { name in
            guard let body = services[name] as? [String: Any] else { return nil }
            guard let image = body["image"] as? String else { return nil }
            let digest = facts.first {
                $0.image == image || image.hasPrefix($0.image) || $0.image.hasPrefix(image)
            }?.digest
            return DeploymentServicePin(name: name, image: image, digest: digest)
        }
    }

    private static func digestsMatch(
        target: [String],
        id: String,
        project: String,
        dataDir: URL,
    ) -> Bool {
        let wanted = Set(target.map(ApplicationImageFacts.normalizeDigest).filter { !$0.isEmpty })
        if wanted.isEmpty { return false }
        let running = (try? ApplicationImageFacts.running(id: id, project: project, dataDir: dataDir)) ?? []
        let have = Set(running.compactMap(\.digest).map(ApplicationImageFacts.normalizeDigest))
        return wanted.isSubset(of: have)
    }

    private static func waitUntilReady(id: String, project: String, dataDir: URL) async -> Bool {
        let timeout = WorkloadEffectGate.readinessTimeout
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            if let services = try? ApplicationServiceHealth.observe(id: id, project: project, dataDir: dataDir),
               ApplicationReadiness.passed(services) {
                return true
            }
            if timeout <= 0 || Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func copyEnv(root: URL, revisionID: String) -> String? {
        let env = root.appendingPathComponent(".env")
        guard FileManager.default.fileExists(atPath: env.path) else { return nil }
        let dir = root.appendingPathComponent("revisions", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let relative = "revisions/\(revisionID).env"
            let dest = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: env, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            return relative
        } catch {
            return nil
        }
    }

    private static func readEnvFile(root: URL, ref: String?) -> [String: String]? {
        guard let ref, !ref.isEmpty else { return nil }
        let url = root.appendingPathComponent(ref)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let eq = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<eq])
            var value = String(text[text.index(after: eq)...])
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            }
            out[key] = value
        }
        return out
    }

    private static func checkpoint(
        operation: WorkloadOperationRecord,
        db: DatabasePool,
        phase: String,
        progress: Double? = nil,
    ) async throws {
        guard try await WorkloadOperationStore.setPhase(
            db: db,
            operationID: operation.id,
            attemptID: operation.attemptID,
            phase: phase,
            progress: progress,
        ) else {
            throw WorkloadOperationInterrupted()
        }
        do {
            try WorkloadEffectGate.pass(phase)
        } catch is WorkloadOperationInterrupted {
            throw WorkloadOperationInterrupted()
        }
    }

    private static func report(
        operation: WorkloadOperationRecord,
        db: DatabasePool,
        progress value: Double,
        callback: (@Sendable (Double) -> Void)?,
    ) async throws {
        guard try await WorkloadOperationStore.recordProgress(
            db: db,
            operationID: operation.id,
            attemptID: operation.attemptID,
            progress: value,
        ) else {
            throw WorkloadOperationInterrupted()
        }
        callback?(value)
    }

    private static func currentPhase(
        operation: WorkloadOperationRecord,
        db: DatabasePool,
    ) async throws -> String {
        guard let row = try await WorkloadOperationStore.fetch(db: db, id: operation.id) else {
            throw BarkVisorError.notFound("operation \(operation.id) not found")
        }
        guard row.attemptID == operation.attemptID else { throw WorkloadOperationInterrupted() }
        return row.phase
    }

    private static func rank(_ phase: String) -> Int {
        phaseRank[phase] ?? 0
    }

    private static func reload(id: String, db: DatabasePool) async throws -> VM {
        guard let vm = try await db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw BarkVisorError.notFound("Workload \(id) not found")
        }
        return vm
    }
}

public enum VMAdoptionProbe {
    @TaskLocal public static var alive: (@Sendable (String, URL) -> Bool)?
}

public enum WorkloadOperationRecovery {
    public static func resume(db: DatabasePool, dataDir: URL = Config.dataDir) async {
        await ApplicationDeployment.recoverOpen(db: db, dataDir: dataDir)
    }
}
