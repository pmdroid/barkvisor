import Foundation
import GRDB

public enum ApplicationLifecycleService {
    private actor Serial {
        func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
            try await body()
        }
    }

    private static let serial = Serial()
    private nonisolated(unsafe) static var lastErrors: [String: String] = [:]

    public static func lastError(for id: String) -> String? {
        lastErrors[id]
    }

    private static func setLastError(id: String, _ error: String?) {
        if let error {
            lastErrors[id] = error
        } else {
            lastErrors.removeValue(forKey: id)
        }
    }

    public static func prepare(
        id: String,
        composeYaml: String,
        env: [String: String]?,
        dataDir: URL = Config.dataDir,
    ) throws -> ComposeRender {
        let dir = ComposeRuntime.projectDirectory(id: id, dataDir: dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let render = try ComposeAllowlist.render(
            yaml: composeYaml,
            workloadID: id,
            stateDir: dir,
            bindHost: HostInfoService.lanBindIPv4(),
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
    ) async throws {
        let snapshot = vm
        vm = try await serial.run { () -> VM in
            var current = snapshot
            try await syncProjectLocked(vm: &current, db: db, dataDir: dataDir)
            return current
        }
    }

    public static func start(vm: inout VM, db: DatabasePool, dataDir: URL = Config.dataDir) async throws {
        let snapshot = vm
        vm = try await serial.run { () -> VM in
            var current = snapshot
            try await startLocked(vm: &current, db: db, dataDir: dataDir)
            return current
        }
    }

    public static func stop(vm: inout VM, db: DatabasePool, dataDir: URL = Config.dataDir) async throws {
        let snapshot = vm
        vm = try await serial.run { () -> VM in
            var current = snapshot
            try await stopLocked(vm: &current, db: db, dataDir: dataDir)
            return current
        }
    }

    public static func restart(vm: inout VM, db: DatabasePool, dataDir: URL = Config.dataDir) async throws {
        let snapshot = vm
        vm = try await serial.run { () -> VM in
            var current = snapshot
            try await restartLocked(vm: &current, db: db, dataDir: dataDir)
            return current
        }
    }

    public static func down(vm: VM, dataDir: URL = Config.dataDir) async {
        try? await serial.run {
            downLocked(vm: vm, dataDir: dataDir)
        }
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

    public static func reconcile(db: DatabasePool, dataDir: URL = Config.dataDir) async {
        guard let labeled = ComposeRuntime.listLabeledStates() else { return }
        let apps: [VM]
        do {
            apps = try await db.read { db in
                try VM.filter(Column("kind") == WorkloadSpec.kindApplication).fetchAll(db)
            }
        } catch {
            Log.vm.warning("Application reconcile list failed: \(error.localizedDescription)")
            return
        }
        for var vm in apps {
            if vm.state == "deleting" { continue }
            let observed = labeled[vm.id]
            if let observed {
                if vm.state != observed {
                    try? await setState(&vm, state: observed, error: nil, db: db)
                }
                continue
            }
            if vm.state == "running" {
                try? await setState(
                    &vm,
                    state: "error",
                    error: "compose project is missing on the Device",
                    db: db,
                )
            }
            _ = dataDir
        }
    }

    public static func portRules(_ ports: [PublishedPort]) -> [PortForwardRule] {
        ports.map {
            PortForwardRule(protocol: $0.proto, hostPort: $0.hostPort, guestPort: $0.containerPort)
        }
    }

    static func verifyInspectedBinds(
        containerNames: [String],
        bindHost: String,
        expected: [PublishedPort],
    ) throws {
        let data = try DockerInspect.jsonForContainers(containerNames)
        let bindings = try ComposePorts.parseInspectBindings(data)
        let allowWildcard = PlatformHost.platformName == "macOS"
        try ComposePorts.requireLANHostIP(
            bindings,
            bindHost: bindHost,
            expected: expected,
            allowWildcard: allowWildcard,
        )
    }

    public static func openURL(from ports: [PublishedPort]) -> String? {
        ports.compactMap(\.openURL).first
    }

    public static func projectName(_ vm: VM) -> String {
        if let name = vm.composeProject, !name.isEmpty { return name }
        return ComposeRuntime.composeProjectName(id: vm.id)
    }

    private static func syncProjectLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        try await refuseDeleting(id: vm.id, db: db)
        try DockerEngine.requireDeviceRuntime()
        if vm.state == "running" {
            try await startLocked(vm: &vm, db: db, dataDir: dataDir)
            return
        }
        if let yaml = vm.composeYaml {
            let render = try prepare(id: vm.id, composeYaml: yaml, env: decodeEnv(vm), dataDir: dataDir)
            try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
            try await setState(&vm, state: vm.state, error: lastError(for: vm.id), db: db)
        }
    }

    private static func startLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        try await refuseDeleting(id: vm.id, db: db)
        try DockerEngine.requireDeviceRuntime()
        let project = projectName(vm)
        let yaml = vm.composeYaml ?? ""
        let render = try prepare(id: vm.id, composeYaml: yaml, env: decodeEnv(vm), dataDir: dataDir)
        try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
        do {
            try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
            try verifyInspectedBinds(
                containerNames: render.containerNames,
                bindHost: render.bindHost,
                expected: render.publishedPorts,
            )
            try await setState(&vm, state: "running", error: nil, db: db)
        } catch {
            try? ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            vm.setPortForwards(nil)
            try await setState(&vm, state: "error", error: message, db: db)
            throw error
        }
    }

    private static func stopLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        try await refuseDeleting(id: vm.id, db: db)
        let project = projectName(vm)
        do {
            try ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            try await setState(&vm, state: "stopped", error: nil, db: db)
        } catch {
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            try await setState(&vm, state: "error", error: message, db: db)
            throw error
        }
    }

    private static func restartLocked(
        vm: inout VM,
        db: DatabasePool,
        dataDir: URL,
    ) async throws {
        try await refuseDeleting(id: vm.id, db: db)
        try DockerEngine.requireDeviceRuntime()
        let project = projectName(vm)
        let yaml = vm.composeYaml ?? ""
        let render = try prepare(id: vm.id, composeYaml: yaml, env: decodeEnv(vm), dataDir: dataDir)
        try await applyPublishedPorts(render.publishedPorts, to: &vm, db: db)
        do {
            try ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            try ComposeRuntime.up(id: vm.id, project: project, dataDir: dataDir)
            try verifyInspectedBinds(
                containerNames: render.containerNames,
                bindHost: render.bindHost,
                expected: render.publishedPorts,
            )
            try await setState(&vm, state: "running", error: nil, db: db)
        } catch {
            try? ComposeRuntime.stop(id: vm.id, project: project, dataDir: dataDir)
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            vm.setPortForwards(nil)
            try await setState(&vm, state: "error", error: message, db: db)
            throw error
        }
    }

    private static func downLocked(vm: VM, dataDir: URL) {
        let project = projectName(vm)
        do {
            try ComposeRuntime.down(id: vm.id, project: project, dataDir: dataDir)
        } catch {
            let message = (error as? BarkVisorError)?.errorDescription ?? error.localizedDescription
            Log.vm.warning("Application \(vm.id) compose down failed: \(message)", vm: vm.id)
        }
        ComposeRuntime.removeProject(id: vm.id, dataDir: dataDir)
    }

    private static func refuseDeleting(id: String, db: DatabasePool) async throws {
        let state = try await db.read { db in try VM.fetchOne(db, key: id)?.state }
        if state == "deleting" {
            throw BarkVisorError.conflict("Workload is deleting")
        }
    }

    private static func applyPublishedPorts(
        _ ports: [PublishedPort],
        to vm: inout VM,
        db: DatabasePool,
    ) async throws {
        let rules = portRules(ports)
        try await PortRegistry.assertAvailable(rules, excludingVM: vm.id, db: db)
        vm.setPortForwards(rules.isEmpty ? nil : rules)
    }

    private static func decodeEnv(_ vm: VM) -> [String: String]? {
        WorkloadSpecJSON.decode(vm.specJson)?.spec.env
    }

    private static func setState(
        _ vm: inout VM,
        state: String,
        error: String?,
        db: DatabasePool,
    ) async throws {
        let now = iso8601.string(from: Date())
        var next = vm
        next.state = state
        next.updatedAt = now
        setLastError(id: next.id, error)
        next.syncSpecProjection(bumpGeneration: false)
        let persisted = next
        let applied = try await db.write { db -> Bool in
            guard let current = try VM.fetchOne(db, key: persisted.id) else {
                throw BarkVisorError.notFound()
            }
            if current.state == "deleting" {
                return false
            }
            try persisted.update(db)
            return true
        }
        if !applied {
            throw BarkVisorError.conflict("Workload is deleting")
        }
        vm = persisted
        if let error {
            Log.vm.warning("Application \(vm.id) \(state): \(error)", vm: vm.id)
        }
    }
}
