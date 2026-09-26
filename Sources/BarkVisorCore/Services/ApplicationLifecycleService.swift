import Foundation
import GRDB

public enum ApplicationLifecycleService {
    private nonisolated(unsafe) static var lastErrors: [String: String] = [:]
    private nonisolated(unsafe) static var metricsCollector: MetricsCollector?
    private nonisolated(unsafe) static var observation: RuntimeObservation?

    public static func setMetricsCollector(_ collector: MetricsCollector?) {
        metricsCollector = collector
    }

    public static func setObservation(_ observation: RuntimeObservation?) {
        self.observation = observation
    }

    public static func lastError(for id: String) -> String? {
        lastErrors[id]
    }

    public static func taskID(forUpdate id: String) -> String {
        "app-update:\(id)"
    }

    public static func taskID(forCreate id: String) -> String {
        "app-create:\(id)"
    }

    public static func resumePending(
        db: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
        operations: WorkloadOperationCoordinator? = nil,
    ) async {
        let operations = operations ?? WorkloadOperationCoordinator()
        let apps: [VM]
        do {
            apps = try await db.read { db in
                try VM
                    .filter(Column("kind") == WorkloadSpec.kindApplication)
                    .filter(Column("state") == "provisioning" || Column("state") == "starting")
                    .fetchAll(db)
            }
        } catch {
            Log.vm.warning("Application resume list failed: \(error.localizedDescription)")
            return
        }
        for vm in apps {
            let workloadID = vm.id
            _ = await backgroundTasks.submit(taskID(forCreate: workloadID), kind: .appCreate) {
                guard var live = try await db.read({ db in try VM.fetchOne(db, key: workloadID) }) else {
                    throw BarkVisorError.notFound("Workload \(workloadID) not found")
                }
                if live.state == "deleting" || live.state == "running" {
                    return workloadID
                }
                try await ApplicationLifecycleService.start(
                    vm: &live,
                    db: db,
                    operations: operations,
                    operationID: "recover:\(workloadID)",
                )
                return workloadID
            }
        }
    }

    public static func publishedUpdate(
        event: BackgroundTaskManager.TaskEvent?,
    ) -> (taskID: String?, progress: Double?) {
        guard let event else { return (nil, nil) }
        switch event.status {
        case .queued, .running:
            return (event.taskID, event.progress ?? 0)
        case .completed, .failed, .cancelled:
            return (nil, nil)
        }
    }

    private static func setLastError(id: String, _ error: String?) {
        if let error {
            lastErrors[id] = error
        } else {
            lastErrors.removeValue(forKey: id)
        }
    }

    static func renderProject(
        vm: VM,
        dataDir: URL,
        gpuShare: GPUShareAttach = .empty,
        catalog: AppCatalogEntryDTO? = nil,
    ) throws -> ComposeRender {
        try prepare(
            id: vm.id,
            composeYaml: vm.composeYaml ?? "",
            env: decodeEnv(vm, dataDir: dataDir, catalog: catalog),
            dataDir: dataDir,
            allowedBinds: vm.decodedSharedPaths,
            gpuShare: gpuShare,
            acceptedResources: WorkloadResources(cpu: vm.cpuCount, memoryMb: vm.memoryMb),
        )
    }

    public static func prepare(
        id: String,
        composeYaml: String,
        env: [String: String]?,
        dataDir: URL = Config.dataDir,
        allowedBinds: [String] = [],
        gpuShare: GPUShareAttach = .empty,
        acceptedResources: WorkloadResources? = nil,
    ) throws -> ComposeRender {
        let dir = ComposeRuntime.projectDirectory(id: id, dataDir: dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let render = try ComposeAllowlist.render(
            yaml: composeYaml,
            workloadID: id,
            stateDir: dir,
            bindHost: nil,
            allowedBinds: allowedBinds,
            gpuShare: gpuShare,
            acceptedResources: acceptedResources,
        )
        for name in render.namedVolumes {
            let volume = dir
                .appendingPathComponent("volumes", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        }
        _ = try ComposeRuntime.writeProject(id: id, yaml: render.yaml, env: env, dataDir: dataDir)
        return render
    }

    public static func syncProject(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
        lease: WorkloadOperationLease? = nil,
    ) async throws {
        if let lease {
            guard let operations else {
                throw BarkVisorError.conflict("Workload operation owner is missing")
            }
            let id = vm.id
            guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                throw BarkVisorError.notFound("Workload \(id) not found")
            }
            try await syncProjectLocked(
                vm: &current, db: db, dataDir: dataDir, lease: lease, operations: operations,
            )
            vm = current
            return
        }
        let id = vm.id
        let operations = operations ?? WorkloadOperationCoordinator()
        let operationID = WorkloadOperationCoordinator.makeOperationID(
            supplied: operationID, action: "sync", workloadID: id,
        )
        vm = try await operations.perform(
            workloadID: id,
            operationID: operationID,
            kind: .sync,
            load: { try await WorkloadOperationCoordinator.observation(id: id, db: db) },
        ) { lease in
            guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                throw BarkVisorError.notFound("Workload \(id) not found")
            }
            try await syncProjectLocked(
                vm: &current, db: db, dataDir: dataDir, lease: lease, operations: operations,
            )
            return current
        }
    }

    public static func start(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
    ) async throws {
        let id = vm.id
        let operations = operations ?? WorkloadOperationCoordinator()
        let operationID = WorkloadOperationCoordinator.makeOperationID(
            supplied: operationID, action: "start", workloadID: id,
        )
        do {
            vm = try await operations.perform(
                workloadID: id,
                operationID: operationID,
                kind: .start,
                load: { try await WorkloadOperationCoordinator.observation(id: id, db: db) },
            ) { lease in
                guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                    throw BarkVisorError.notFound("Workload \(id) not found")
                }
                try await startLocked(
                    vm: &current, db: db, dataDir: dataDir, lease: lease, operations: operations,
                )
                return current
            }
        } catch {
            if let stored = try await db.read({ db in try VM.fetchOne(db, key: id) }) {
                vm = stored
            }
            throw error
        }
    }

    public static func stop(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
    ) async throws {
        let id = vm.id
        let operations = operations ?? WorkloadOperationCoordinator()
        let operationID = WorkloadOperationCoordinator.makeOperationID(
            supplied: operationID, action: "stop", workloadID: id,
        )
        vm = try await operations.perform(
            workloadID: id,
            operationID: operationID,
            kind: .stop,
            load: { try await WorkloadOperationCoordinator.observation(id: id, db: db) },
        ) { lease in
            guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                throw BarkVisorError.notFound("Workload \(id) not found")
            }
            try await stopLocked(
                vm: &current, db: db, dataDir: dataDir, lease: lease, operations: operations,
            )
            return current
        }
    }

    public static func restart(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
    ) async throws {
        let id = vm.id
        let operations = operations ?? WorkloadOperationCoordinator()
        let operationID = WorkloadOperationCoordinator.makeOperationID(
            supplied: operationID, action: "restart", workloadID: id,
        )
        do {
            vm = try await operations.perform(
                workloadID: id,
                operationID: operationID,
                kind: .restart,
                load: { try await WorkloadOperationCoordinator.observation(id: id, db: db) },
            ) { lease in
                guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                    throw BarkVisorError.notFound("Workload \(id) not found")
                }
                try await restartLocked(
                    vm: &current, db: db, dataDir: dataDir, lease: lease, operations: operations,
                )
                return current
            }
        } catch {
            if let stored = try await db.read({ db in try VM.fetchOne(db, key: id) }) {
                vm = stored
            }
            throw error
        }
    }

    public static func updateImages(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws {
        let id = vm.id
        let operations = operations ?? WorkloadOperationCoordinator()
        let operationID = WorkloadOperationCoordinator.makeOperationID(
            supplied: operationID, action: "update", workloadID: id,
        )
        vm = try await operations.perform(
            workloadID: id,
            operationID: operationID,
            kind: .update,
            load: { try await WorkloadOperationCoordinator.observation(id: id, db: db) },
        ) { lease in
            guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                throw BarkVisorError.notFound("Workload \(id) not found")
            }
            try await updateImagesLocked(
                vm: &current,
                db: db,
                dataDir: dataDir,
                lease: lease,
                operations: operations,
                progress: progress,
            )
            return current
        }
    }

    public static func refreshImageFacts(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
    ) async throws {
        let id = vm.id
        let operations = operations ?? WorkloadOperationCoordinator()
        let operationID = WorkloadOperationCoordinator.makeOperationID(
            supplied: operationID, action: "refresh", workloadID: id,
        )
        vm = try await operations.perform(
            workloadID: id,
            operationID: operationID,
            kind: .update,
            load: { try await WorkloadOperationCoordinator.observation(id: id, db: db) },
        ) { lease in
            guard var current = try await db.read({ try VM.fetchOne($0, key: id) }) else {
                throw BarkVisorError.notFound("Workload \(id) not found")
            }
            try await refreshImageFactsLocked(
                vm: &current, db: db, dataDir: dataDir, lease: lease, operations: operations,
            )
            return current
        }
    }

    public static func logs(vm: VM, tail: Int = 200, dataDir: URL = Config.dataDir) throws -> String {
        let project = projectName(vm)
        return try ComposeRuntime.logs(id: vm.id, project: project, tail: tail, dataDir: dataDir)
    }

    public static func followLogs(
        vm: VM,
        tail: Int = 200,
        dataDir: URL = Config.dataDir,
    ) throws -> AsyncThrowingStream<String, Error> {
        let project = projectName(vm)
        return try ComposeRuntime.followLogs(id: vm.id, project: project, tail: tail, dataDir: dataDir)
    }

    public static func down(
        vm: VM,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
        operationID: String? = nil,
        holdingSlot: Bool = false,
    ) async {
        if holdingSlot {
            downLocked(vm: vm, dataDir: dataDir)
        } else {
            let operations = operations ?? WorkloadOperationCoordinator()
            let operationID = WorkloadOperationCoordinator.makeOperationID(
                supplied: operationID, action: "down", workloadID: vm.id,
            )
            let generation = vm.specGeneration
            let state = vm.state
            try? await operations.perform(
                workloadID: vm.id,
                operationID: operationID,
                kind: .delete,
                load: {
                    LeaseObservation(generation: generation, state: state, exists: true)
                },
            ) { _ in
                downLocked(vm: vm, dataDir: dataDir)
            }
        }
        await metricsCollector?.stop(vmID: vm.id)
    }

    public static func refreshState(vm: inout VM, db: DatabasePool, dataDir: URL = Config.dataDir) async throws {
        let project = projectName(vm)
        let state: String
        do {
            state = try ComposeRuntime.psState(id: vm.id, project: project, dataDir: dataDir)
        } catch {
            return
        }
        if vm.state != state {
            try await setState(&vm, state: state, error: nil, db: db)
        }
    }

    public static func reconcile(
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        operations: WorkloadOperationCoordinator? = nil,
    ) async {
        let operations = operations ?? WorkloadOperationCoordinator()
        let apps: [VM]
        do {
            apps = try await db.read { db in
                try VM.filter(Column("kind") == WorkloadSpec.kindApplication).fetchAll(db)
            }
        } catch {
            Log.vm.warning("Application reconcile list failed: \(error.localizedDescription)")
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for vm in apps {
                let workloadID = vm.id
                group.addTask {
                    let operationID = "reconcile:\(workloadID):\(UUID().uuidString)"
                    try? await operations.perform(
                        workloadID: workloadID,
                        operationID: operationID,
                        kind: .reconcile,
                        load: { try await WorkloadOperationCoordinator.observation(id: workloadID, db: db) },
                    ) { lease in
                        try await reconcileLocked(
                            id: workloadID,
                            db: db,
                            dataDir: dataDir,
                            lease: lease,
                            operations: operations,
                        )
                    }
                }
            }
        }
    }

    public static func portRules(_ ports: [PublishedPort]) -> [PortForwardRule] {
        ports.map {
            PortForwardRule(
                protocol: $0.proto,
                hostPort: $0.hostPort,
                guestPort: $0.containerPort,
                host: $0.hostAddress,
            )
        }
    }

    static func verifyInspectedBinds(
        containerNames: [String],
        bindHost: String,
        expected: [PublishedPort],
    ) throws {
        let data = try DockerInspect.json(containerNames)
        let bindings = try ComposePorts.parseInspectBindings(data)
        try ComposePorts.requireLANHostIP(
            bindings,
            bindHost: bindHost,
            expected: expected,
            allowWildcard: false,
        )
    }

    public static func openURL(from ports: [PublishedPort]) -> String? {
        ports.compactMap(\.openURL).first
    }

    public static func openURL(
        id: String,
        ports: [PublishedPort],
        spec: WorkloadSpec?,
        listenPort: Int = Config.port,
        lanHost: String? = HostInfoService.lanBindIPv4(),
    ) -> String? {
        AppIngress.openURL(
            id: id,
            catalogProxy: spec?.spec.ingress?.mode,
            ingress: spec?.spec.ingress,
            lanURL: openURL(from: ports),
            listenHost: lanHost,
            listenPort: listenPort,
        )
    }

    public static func projectName(_ vm: VM) -> String {
        if let name = vm.composeProject, !name.isEmpty { return name }
        return ComposeRuntime.composeProjectName(id: vm.id)
    }
}

extension ApplicationLifecycleService {
    private static func syncProjectLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        try await requireCurrent(lease: lease, db: db, operations: operations)
        try DockerEngine.requireDeviceRuntime()
        if vm.state == "running" {
            try await startLocked(
                vm: &vm, db: db, dataDir: dataDir, lease: lease, operations: operations,
            )
            return
        }
        if vm.composeYaml != nil {
            let gpuShare = try await shareAttach(for: vm, db: db)
            let catalog = await catalogEntry(for: vm, db: db)
            let render = try renderProject(vm: vm, dataDir: dataDir, gpuShare: gpuShare, catalog: catalog)
            try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
            try await persistRuntime(
                vm: &vm,
                namedVolumes: render.namedVolumes,
                db: db,
                dataDir: dataDir,
                generation: lease.generation,
            )
            try await setState(
                &vm, state: vm.state, error: lastError(for: vm.id), db: db, generation: lease.generation,
            )
        }
    }

    private static func startLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        try await requireCurrent(lease: lease, db: db, operations: operations)
        try DockerEngine.requireDeviceRuntime()
        let project = projectName(vm)
        let gpuShare = try await shareAttach(for: vm, db: db)
        let catalog = await catalogEntry(for: vm, db: db)
        let render = try renderProject(vm: vm, dataDir: dataDir, gpuShare: gpuShare, catalog: catalog)
        try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
        do {
            if vm.state == "provisioning" {
                try ComposeRuntime.pull(id: vm.id, project: project, dataDir: dataDir)
            }
            try await requireCurrent(lease: lease, db: db, operations: operations)
            if await lease.isCancelRequested() {
                try? ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
                try await setState(
                    &vm,
                    state: "error",
                    error: "start cancelled",
                    db: db,
                    generation: lease.generation,
                )
                throw CancellationError()
            }
            try await setState(&vm, state: "starting", error: nil, db: db, generation: lease.generation)
            try await requireCurrent(lease: lease, db: db, operations: operations)
            try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
            try verifyInspectedBinds(
                containerNames: render.containerNames,
                bindHost: render.bindHost,
                expected: render.publishedPorts,
            )
            try await requireCurrent(lease: lease, db: db, operations: operations)
            try await persistRuntime(
                vm: &vm,
                namedVolumes: render.namedVolumes,
                db: db,
                dataDir: dataDir,
                generation: lease.generation,
            )
            let limits = enforcedLimits(vm)
            try await setState(
                &vm,
                state: "running",
                error: nil,
                db: db,
                generation: lease.generation,
                services: serviceObservations(
                    containerNames: render.containerNames,
                    composeYaml: vm.composeYaml,
                ),
                enforcedCpu: limits.cpu,
                enforcedMemoryMb: limits.memoryMb,
                claimApplied: true,
            )
            await metricsCollector?.startApp(id: vm.id, project: project)
        } catch {
            try? ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            vm.setPortForwards(nil)
            await recordLifecycleError(&vm, message: message, db: db, generation: lease.generation)
            throw error
        }
    }

    private static func stopLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        try await requireCurrent(lease: lease, db: db, operations: operations)
        let project = projectName(vm)
        do {
            try ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            try await setState(&vm, state: "stopped", error: nil, db: db, generation: lease.generation)
            await metricsCollector?.stop(vmID: vm.id)
        } catch {
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            await recordLifecycleError(&vm, message: message, db: db, generation: lease.generation)
            throw error
        }
    }

    private static func restartLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        try await requireCurrent(lease: lease, db: db, operations: operations)
        try DockerEngine.requireDeviceRuntime()
        let project = projectName(vm)
        let gpuShare = try await shareAttach(for: vm, db: db)
        let catalog = await catalogEntry(for: vm, db: db)
        let render = try renderProject(vm: vm, dataDir: dataDir, gpuShare: gpuShare, catalog: catalog)
        try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
        do {
            try await requireCurrent(lease: lease, db: db, operations: operations)
            try ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            try await requireCurrent(lease: lease, db: db, operations: operations)
            try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
            try verifyInspectedBinds(
                containerNames: render.containerNames,
                bindHost: render.bindHost,
                expected: render.publishedPorts,
            )
            try await persistRuntime(
                vm: &vm,
                namedVolumes: render.namedVolumes,
                db: db,
                dataDir: dataDir,
                generation: lease.generation,
            )
            let limits = enforcedLimits(vm)
            try await setState(
                &vm,
                state: "running",
                error: nil,
                db: db,
                generation: lease.generation,
                services: serviceObservations(
                    containerNames: render.containerNames,
                    composeYaml: vm.composeYaml,
                ),
                enforcedCpu: limits.cpu,
                enforcedMemoryMb: limits.memoryMb,
                claimApplied: true,
            )
            await metricsCollector?.startApp(id: vm.id, project: project)
        } catch {
            try? ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            vm.setPortForwards(nil)
            await recordLifecycleError(&vm, message: message, db: db, generation: lease.generation)
            throw error
        }
    }

    private static func updateImagesLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
        progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        try await requireCurrent(lease: lease, db: db, operations: operations)
        try await requireRunning(id: vm.id, db: db)
        try DockerEngine.requireDeviceRuntime()
        let project = projectName(vm)
        let render = try renderProject(vm: vm, dataDir: dataDir)
        try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
        progress?(0.2)
        try await requireCurrent(lease: lease, db: db, operations: operations)
        if await lease.isCancelRequested() {
            throw CancellationError()
        }
        try ComposeRuntime.pull(id: vm.id, project: project, dataDir: dataDir)
        progress?(0.6)
        try await requireCurrent(lease: lease, db: db, operations: operations)
        if await lease.isCancelRequested() {
            try? ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            try await setState(
                &vm,
                state: "error",
                error: "update cancelled",
                db: db,
                generation: lease.generation,
            )
            throw CancellationError()
        }
        try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
        progress?(0.85)
        try verifyInspectedBinds(
            containerNames: render.containerNames,
            bindHost: render.bindHost,
            expected: render.publishedPorts,
        )
        try await persistRuntime(
            vm: &vm,
            namedVolumes: render.namedVolumes,
            db: db,
            dataDir: dataDir,
            generation: lease.generation,
        )
        try await refreshCatalogDigest(vm: &vm, db: db, dataDir: dataDir, generation: lease.generation)
        let limits = enforcedLimits(vm)
        try await setState(
            &vm,
            state: "running",
            error: nil,
            db: db,
            generation: lease.generation,
            services: serviceObservations(
                containerNames: render.containerNames,
                composeYaml: vm.composeYaml,
            ),
            enforcedCpu: limits.cpu,
            enforcedMemoryMb: limits.memoryMb,
            claimApplied: true,
        )
        await metricsCollector?.startApp(id: vm.id, project: project)
        progress?(1.0)
    }

    private static func refreshImageFactsLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        try await requireCurrent(lease: lease, db: db, operations: operations)
        let yaml = vm.composeYaml ?? ""
        let dir = ComposeRuntime.projectDirectory(id: vm.id, dataDir: dataDir)
        let named: [String] = if yaml.isEmpty {
            []
        } else if let render = try? ComposeAllowlist.render(
            yaml: yaml,
            workloadID: vm.id,
            stateDir: dir,
        ) {
            render.namedVolumes
        } else {
            []
        }
        try await persistRuntime(
            vm: &vm, namedVolumes: named, db: db, dataDir: dataDir, generation: lease.generation,
        )
        try await refreshCatalogDigest(vm: &vm, db: db, dataDir: dataDir, generation: lease.generation)
    }

    private static func downLocked(vm: VM, dataDir: URL) {
        let project = projectName(vm)
        do {
            try ComposeRuntime.down(id: vm.id, project: project, dataDir: dataDir)
            ComposeRuntime.removeProject(id: vm.id, dataDir: dataDir)
        } catch {
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            Log.vm.warning("Application \(vm.id) compose down failed: \(message)", vm: vm.id)
            return
        }
    }

    private static func recordLifecycleError(
        _ vm: inout VM,
        message: String,
        db: DatabasePool,
        generation: Int,
    ) async {
        do {
            try await setState(&vm, state: "error", error: message, db: db, generation: generation)
        } catch {
            let now = iso8601.string(from: Date())
            let id = vm.id
            let wrote = try? await db.write { db -> Bool in
                try db.execute(
                    sql: """
                    UPDATE vms SET state = 'error', updatedAt = ?
                    WHERE id = ? AND state IN ('starting', 'stopping', 'provisioning')
                    """,
                    arguments: [now, id],
                )
                return db.changesCount > 0
            }
            guard wrote == true else { return }
            vm.state = "error"
            vm.updatedAt = now
            setLastError(id: id, message)
        }
    }

    private static func requireCurrent(
        lease: WorkloadOperationLease,
        db: DatabasePool,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        let current = try await WorkloadOperationCoordinator.observation(
            id: lease.identity.workloadID, db: db,
        )
        if current.exists, current.state == "deleting", lease.kind != .delete {
            throw BarkVisorError.conflict("Workload is deleting")
        }
        guard await operations.allowsWrite(lease: lease, current: current) else {
            throw BarkVisorError.conflict(
                "Workload \(lease.identity.workloadID) changed before the operation finished",
            )
        }
    }

    private static func reconcileLocked(
        id: String,
        db: DatabasePool,
        dataDir: URL,
        lease: WorkloadOperationLease,
        operations: WorkloadOperationCoordinator,
    ) async throws {
        guard let labeled = ComposeRuntime.listLabeledStates() else { return }
        guard var vm = try await db.read({ try VM.fetchOne($0, key: id) }) else { return }
        let current = LeaseObservation(generation: vm.specGeneration, state: vm.state, exists: true)
        guard await operations.allowsWrite(lease: lease, current: current) else { return }
        let observed = labeled[vm.id]
        if let observed {
            await observation?.applyReconcile([
                ReconcileFact(
                    workloadID: vm.id,
                    phase: observed == "running" ? .running : .exited,
                    detail: nil,
                ),
            ])
            let services = serviceObservations(
                containerNames: DockerServiceHealth.containerNames(
                    workloadID: vm.id,
                    composeYaml: vm.composeYaml,
                ),
                composeYaml: vm.composeYaml,
            )
            if vm.state != observed || services != nil {
                try? await setState(
                    &vm,
                    state: observed,
                    error: nil,
                    db: db,
                    generation: lease.generation,
                    services: services,
                )
            }
            let fresh = try await WorkloadOperationCoordinator.observation(id: id, db: db)
            guard await operations.allowsWrite(lease: lease, current: fresh) else { return }
            if observed == "running" {
                await metricsCollector?.startApp(id: vm.id, project: projectName(vm))
            } else {
                await metricsCollector?.stopApp(vm.id)
            }
            return
        }
        if vm.state == "running" {
            await observation?.applyReconcile([
                ReconcileFact(
                    workloadID: vm.id,
                    phase: .exited,
                    detail: "compose project is missing on the Device",
                ),
            ])
            try? await setState(
                &vm,
                state: "error",
                error: "compose project is missing on the Device",
                db: db,
                generation: lease.generation,
            )
        }
        await metricsCollector?.stopApp(vm.id)
        _ = dataDir
    }

    static func noteAppRunning(id: String, project: String) async {
        await metricsCollector?.startApp(id: id, project: project)
    }

    static func refuseDeleting(id: String, db: DatabasePool) async throws {
        let state = try await db.read { db in try VM.fetchOne(db, key: id)?.state }
        if state == "deleting" {
            throw BarkVisorError.conflict("Workload is deleting")
        }
    }

    static func requireRunning(id: String, db: DatabasePool) async throws {
        let state = try await db.read { db in try VM.fetchOne(db, key: id)?.state }
        if state != "running" {
            throw BarkVisorError.conflict("Application must be running to update images")
        }
    }

    static func persistRuntime(
        vm: inout VM,
        namedVolumes: [String],
        db: DatabasePool,
        dataDir: URL,
        generation: Int? = nil,
    ) async throws {
        vm.setVolumeRoots(ComposeRuntime.volumeRoots(id: vm.id, named: namedVolumes, dataDir: dataDir))
        if let fact = try? ApplicationImageFacts.running(
            id: vm.id,
            project: projectName(vm),
            dataDir: dataDir,
        ).first {
            vm.imageRef = fact.image
            if let digest = fact.digest {
                vm.digest = digest
            }
        } else if vm.imageRef == nil {
            vm.imageRef = ComposeAllowlist.firstImage(yaml: vm.composeYaml)
        }
        let now = iso8601.string(from: Date())
        vm.updatedAt = now
        let snapshot = vm
        let applied = try await db.write { db -> VM? in
            guard let current = try VM.fetchOne(db, key: snapshot.id) else {
                throw BarkVisorError.notFound()
            }
            if current.state == "deleting" { return nil }
            guard var merged = WorkloadFactStore.mergingRuntimeSnapshot(
                current: current, snapshot: snapshot,
            ) else {
                throw BarkVisorError.conflict(
                    "configuration generation \(current.specGeneration) is newer than \(snapshot.specGeneration)",
                )
            }
            if let generation, current.specGeneration != generation {
                throw BarkVisorError.conflict("Workload changed before the operation finished")
            }
            merged.syncSpecProjection(bumpGeneration: false)
            try merged.update(db)
            return merged
        }
        guard let applied else {
            throw BarkVisorError.conflict("Workload is deleting")
        }
        vm = applied
    }

    static func refreshCatalogDigest(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
        generation: Int? = nil,
    ) async throws {
        let image = vm.imageRef ?? ComposeAllowlist.firstImage(yaml: vm.composeYaml)
        guard let image, !image.isEmpty else { return }
        guard let snap = try? ApplicationImageFacts.snapshot(
            id: vm.id,
            project: projectName(vm),
            image: image,
            dataDir: dataDir,
        ) else { return }
        if !snap.image.isEmpty {
            vm.imageRef = snap.image
        }
        if snap.catalogResolved {
            if let digest = snap.digest {
                vm.digest = digest
            }
            vm.catalogDigest = snap.catalogDigest
        }
        vm.updatedAt = iso8601.string(from: Date())
        let snapshot = vm
        let applied = try await db.write { db -> VM? in
            guard let current = try VM.fetchOne(db, key: snapshot.id) else {
                throw BarkVisorError.notFound()
            }
            if current.state == "deleting" { return nil }
            guard var merged = WorkloadFactStore.mergingRuntimeSnapshot(
                current: current, snapshot: snapshot,
            ) else {
                throw BarkVisorError.conflict(
                    "configuration generation \(current.specGeneration) is newer than \(snapshot.specGeneration)",
                )
            }
            if let generation, current.specGeneration != generation {
                throw BarkVisorError.conflict("Workload changed before the operation finished")
            }
            merged.syncSpecProjection(bumpGeneration: false)
            try merged.update(db)
            return merged
        }
        guard let applied else {
            throw BarkVisorError.conflict("Workload is deleting")
        }
        vm = applied
    }

    static func applyPublishedPorts(
        _ ports: [PublishedPort],
        to vm: inout VM,
        db: DatabasePool,
    ) async throws {
        let rules = portRules(ports)
        try await PortRegistry.assertAvailable(rules, excludingVM: vm.id, db: db)
        vm.setPortForwards(rules.isEmpty ? nil : rules)
    }

    static func catalogEntry(for vm: VM, db: DatabasePool) async -> AppCatalogEntryDTO? {
        let labels = WorkloadSpecJSON.decode(vm.specJson)?.metadata.labels ?? [:]
        guard let slug = labels["catalog"], !slug.isEmpty else { return nil }
        let source = labels["catalog-source"]
        return try? await db.read { db in
            try AppCatalogRecord.resolve(db: db, slug: slug, source: source)?.dto()
        }
    }

    static func decodeEnv(
        _ vm: VM,
        dataDir: URL,
        catalog: AppCatalogEntryDTO? = nil,
    ) -> [String: String]? {
        let spec = WorkloadSpecJSON.decode(vm.specJson)
        let existing = AppTemplate.mergeEnv(
            existing: spec?.spec.env,
            incoming: nil,
            disk: ComposeRuntime.readEnv(id: vm.id, dataDir: dataDir),
        )
        let lan = HostInfoService.lanBindIPv4()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = lan.isEmpty ? "127.0.0.1" : lan
        let names = AppIngress.envNames(
            catalog: catalog?.ui ?? AppCatalogUI(),
            schema: catalog?.envSchema ?? [],
        )
        let managed = AppIngress.managedEnv(
            id: vm.id,
            names: names,
            catalogProxy: spec?.spec.ingress?.mode,
            ingress: spec?.spec.ingress,
            scheme: "http",
            host: host,
            listenPort: Config.port,
        )
        return AppIngress.mergeEnv(
            existing: existing,
            extra: spec?.spec.ingress?.extraEnv,
            managed: managed,
            enabled: AppIngress.isEnabled(spec?.spec.ingress),
        )
    }

    static func shareAttach(for vm: VM, db: DatabasePool) async throws -> GPUShareAttach {
        let selected = WorkloadSpecJSON.decode(vm.specJson)?.spec.gpuShare ?? []
        if selected.isEmpty { return .empty }
        let vms = try await db.read { db in try VM.fetchAll(db) }
        return try GPUShareService.attach(
            selected: selected,
            inventory: GPUShareService.list(vms: vms),
        )
    }

    static func setState(
        _ vm: inout VM,
        state: String,
        error: String?,
        db: DatabasePool,
        generation: Int? = nil,
        services: [WorkloadServiceObservation]? = nil,
        enforcedCpu: Int? = nil,
        enforcedMemoryMb: Int? = nil,
        claimApplied: Bool = false,
    ) async throws {
        let now = iso8601.string(from: Date())
        let workloadID = vm.id
        let snapshotGeneration = vm.specGeneration
        let identity = vm.runtimeWorkloadId ?? vm.composeProject
        let kind = vm.kind
        let portForwards = vm.portForwards
        setLastError(id: workloadID, error)
        let applied = try await db.write { db -> VM? in
            guard var current = try VM.fetchOne(db, key: workloadID) else {
                throw BarkVisorError.notFound()
            }
            if current.state == "deleting" { return nil }
            if snapshotGeneration != current.specGeneration {
                throw BarkVisorError.conflict(
                    "configuration generation \(current.specGeneration) is newer than \(snapshotGeneration)",
                )
            }
            if let generation, current.specGeneration != generation {
                throw BarkVisorError.conflict("Workload changed before the operation finished")
            }
            current.state = state
            current.updatedAt = now
            current.portForwards = portForwards
            try current.update(db)
            let storedObservation = try WorkloadObservation.fetchOne(db, key: workloadID)
            let observedServices = if claimApplied {
                services ?? []
            } else {
                services ?? storedObservation?.services ?? []
            }
            let storedServicePayload: [WorkloadServiceObservation]? = if claimApplied {
                services ?? []
            } else {
                services
            }
            let appliedGeneration = if claimApplied {
                current.specGeneration
            } else {
                storedObservation?.appliedGeneration ?? current.specGeneration
            }
            let projected = WorkloadHealthProjector.project(
                state: VMState.parse(state),
                signals: WorkloadHealthSignals(lastError: error),
                updatedAt: now,
                kind: kind,
                services: observedServices,
                observedAt: now,
                freshness: "fresh",
                appliedGeneration: appliedGeneration,
            )
            _ = try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: current.id,
                appliedGeneration: appliedGeneration,
                runtimeIdentity: identity,
                processState: state,
                readiness: projected.readiness ?? "unknown",
                condition: projected.condition ?? "unknown",
                observedAt: now,
                error: error,
                freshness: "fresh",
                enforcedCpu: enforcedCpu,
                enforcedMemoryMb: enforcedMemoryMb,
                services: storedServicePayload,
            )
            return current
        }
        guard let applied else {
            throw BarkVisorError.conflict("Workload is deleting")
        }
        vm.state = applied.state
        vm.updatedAt = applied.updatedAt
        if let error {
            Log.vm.warning("Application \(vm.id) \(state): \(error)", vm: vm.id)
        }
    }
}

private func enforcedLimits(_ vm: VM) -> (cpu: Int?, memoryMb: Int?) {
    if vm.cpuCount >= 1, (128 ... 1_048_576).contains(vm.memoryMb) {
        return (vm.cpuCount, vm.memoryMb)
    }
    return (nil, nil)
}

private func serviceObservations(
    containerNames: [String],
    composeYaml: String?,
) -> [WorkloadServiceObservation]? {
    guard let data = try? DockerInspect.json(containerNames) else { return nil }
    return DockerServiceHealth.observations(
        inspectJSON: data,
        roles: DockerServiceHealth.roles(composeYaml: composeYaml),
    )
}
