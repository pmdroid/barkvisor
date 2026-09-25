import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Workload facts")
struct WorkloadFactTests {
    @Test func `older configuration and observation writes lose`() throws {
        let queue = try migratedQueue()
        try insertApplication(queue, id: "app-1", generation: 2, cpu: 1, memory: 128)
        try queue.write { db in
            _ = try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: "app-1",
                appliedGeneration: 2,
                runtimeIdentity: "bv-app-1",
                processState: "running",
                readiness: "ready",
                condition: "healthy",
                observedAt: "2026-09-24T00:00:00Z",
                error: nil,
                freshness: "fresh",
                enforcedCpu: 1,
                enforcedMemoryMb: 128,
                services: [],
            )
        }
        try queue.write { db in
            let updated = try WorkloadFactStore.commitConfiguration(
                db: db, id: "app-1", expectedGeneration: 2,
            ) { vm in
                vm.cpuCount = 4
                vm.memoryMb = 512
                vm.specGeneration = 3
            }
            #expect(updated.cpuCount == 4)
            #expect(updated.specGeneration == 3)
        }
        do {
            try queue.write { db in
                _ = try WorkloadFactStore.commitConfiguration(
                    db: db, id: "app-1", expectedGeneration: 2,
                ) { vm in
                    vm.cpuCount = 1
                }
            }
            Issue.record("older configuration write was accepted")
        } catch let error as BarkVisorError {
            #expect(String(describing: error).contains("newer"))
        }
        do {
            try queue.write { db in
                _ = try WorkloadFactStore.recordObservation(
                    db: db,
                    workloadId: "app-1",
                    appliedGeneration: 1,
                    runtimeIdentity: "old",
                    processState: "stopped",
                    readiness: "unknown",
                    condition: "unknown",
                    observedAt: "2026-09-24T00:00:01Z",
                    error: nil,
                    freshness: "fresh",
                    enforcedCpu: nil,
                    enforcedMemoryMb: nil,
                    services: [],
                )
            }
            Issue.record("older applied generation was accepted")
        } catch is BarkVisorError {}
        let stored = try queue.read { db in
            try (
                VM.fetchOne(db, key: "app-1"),
                WorkloadObservation.fetchOne(db, key: "app-1"),
            )
        }
        #expect(stored.0?.cpuCount == 4)
        #expect(stored.0?.specGeneration == 3)
        #expect(stored.0?.startOnBoot == true)
        #expect(stored.1?.appliedGeneration == 2)
        #expect(stored.1?.processState == "running")
    }

    @Test func `an empty service observation clears the previous containers`() throws {
        let queue = try migratedQueue()
        try insertApplication(queue, id: "app-clear", generation: 1, cpu: 1, memory: 128)
        let web = WorkloadServiceObservation(
            name: "web",
            role: WorkloadServiceObservation.roleLongRunning,
            running: true,
            health: "healthy",
        )
        try queue.write { db in
            _ = try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: "app-clear",
                appliedGeneration: 1,
                runtimeIdentity: nil,
                processState: "running",
                readiness: "ready",
                condition: "healthy",
                observedAt: "2026-09-24T00:00:00Z",
                error: nil,
                freshness: "fresh",
                enforcedCpu: nil,
                enforcedMemoryMb: nil,
                services: [web],
            )
            _ = try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: "app-clear",
                appliedGeneration: 1,
                runtimeIdentity: nil,
                processState: "stopped",
                readiness: "unknown",
                condition: "unknown",
                observedAt: "2026-09-24T00:00:01Z",
                error: nil,
                freshness: "fresh",
                enforcedCpu: nil,
                enforcedMemoryMb: nil,
            )
        }
        let kept = try queue.read { try WorkloadObservation.fetchOne($0, key: "app-clear") }
        #expect(kept?.services == [web])
        #expect(kept?.processState == "stopped")
        try queue.write { db in
            _ = try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: "app-clear",
                appliedGeneration: 1,
                runtimeIdentity: nil,
                processState: "stopped",
                readiness: "not_ready",
                condition: "unknown",
                observedAt: "2026-09-24T00:00:02Z",
                error: nil,
                freshness: "fresh",
                enforcedCpu: nil,
                enforcedMemoryMb: nil,
                services: [],
            )
        }
        let stored = try queue.read { try WorkloadObservation.fetchOne($0, key: "app-clear") }
        #expect(stored?.services.isEmpty == true)
        #expect(stored?.processState == "stopped")
        let status = WorkloadHealthProjector.project(
            state: .stopped,
            updatedAt: "2026-09-24T00:00:01Z",
            kind: WorkloadSpec.kindApplication,
            services: stored?.services ?? [web],
            observedAt: "2026-09-24T00:00:01Z",
            freshness: "fresh",
        )
        #expect(status.condition != "healthy")
        #expect(status.running == false)
        let staleHealthy = WorkloadHealthProjector.project(
            state: .stopped,
            updatedAt: "2026-09-24T00:00:02Z",
            kind: WorkloadSpec.kindApplication,
            services: [web],
            observedAt: "2026-09-24T00:00:02Z",
            freshness: "fresh",
        )
        #expect(staleHealthy.health == .stopped)
        #expect(staleHealthy.condition != "healthy")
        #expect(staleHealthy.running == false)
    }

    @Test func `stale observation sequence cannot overwrite`() throws {
        let queue = try migratedQueue()
        try insertApplication(queue, id: "app-2", generation: 1, cpu: 1, memory: 128)
        let first = try queue.write { db in
            try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: "app-2",
                appliedGeneration: 1,
                runtimeIdentity: nil,
                processState: "running",
                readiness: "unknown",
                condition: "unknown",
                observedAt: "2026-09-24T00:00:00Z",
                error: nil,
                freshness: "fresh",
                enforcedCpu: nil,
                enforcedMemoryMb: nil,
                services: [],
            )
        }
        _ = try queue.write { db in
            try WorkloadFactStore.recordObservation(
                db: db,
                workloadId: "app-2",
                appliedGeneration: 1,
                runtimeIdentity: nil,
                processState: "stopped",
                readiness: "unknown",
                condition: "unknown",
                observedAt: "2026-09-24T00:00:02Z",
                error: nil,
                freshness: "fresh",
                enforcedCpu: nil,
                enforcedMemoryMb: nil,
                services: [],
                basedOnSequence: first.sequence,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try queue.write { db in
                _ = try WorkloadFactStore.recordObservation(
                    db: db,
                    workloadId: "app-2",
                    appliedGeneration: 1,
                    runtimeIdentity: nil,
                    processState: "running",
                    readiness: "ready",
                    condition: "healthy",
                    observedAt: "2026-09-24T00:00:03Z",
                    error: nil,
                    freshness: "fresh",
                    enforcedCpu: nil,
                    enforcedMemoryMb: nil,
                    services: [],
                    basedOnSequence: first.sequence,
                )
            }
        }
    }

    @Test func `runtime snapshot cannot replace a newer configuration`() throws {
        let queue = try migratedQueue()
        try insertApplication(queue, id: "app-3", generation: 4, cpu: 2, memory: 256)
        let current = try #require(try queue.read { try VM.fetchOne($0, key: "app-3") })
        var stale = current
        stale.specGeneration = 3
        stale.cpuCount = 1
        stale.state = "running"
        stale.gpuDevices = #"[{"pciAddress":"0000:01:00.0","iommuGroup":"1","vendorId":"10de","deviceId":"2204","groupAddresses":["0000:01:00.0"]}]"#
        #expect(WorkloadFactStore.mergingRuntimeSnapshot(current: current, snapshot: stale) == nil)
        let kept = try queue.write { db -> VM? in
            if let merged = WorkloadFactStore.mergingRuntimeSnapshot(current: current, snapshot: stale) {
                try merged.update(db)
            }
            return try VM.fetchOne(db, key: "app-3")
        }
        #expect(kept?.cpuCount == 2)
        #expect(kept?.specGeneration == 4)
        #expect(kept?.gpuDevices == nil)
    }

    @Test func `delivered view cannot overwrite daemon facts`() throws {
        let queue = try migratedQueue()
        try insertApplication(queue, id: "app-4", generation: 5, cpu: 1, memory: 128)
        let vm = try #require(try queue.read { try VM.fetchOne($0, key: "app-4") })
        let authoritative = WorkloadFactStore.projection(vm: vm, observation: nil)
        let cached = WorkloadFactStore.disconnect(authoritative)
        #expect(cached.freshness == "stale")
        #expect(cached.configurationGeneration == 5)
        let refreshed = WorkloadFactStore.reconnect(
            authoritative: WorkloadDeliveredView(
                id: vm.id,
                configurationGeneration: 6,
                appliedGeneration: 6,
                processState: "running",
                readiness: "ready",
                condition: "healthy",
                freshness: "fresh",
            ),
        )
        #expect(refreshed.configurationGeneration == 6)
        #expect(refreshed.freshness == "fresh")
        #expect(throws: BarkVisorError.self) {
            try queue.write { db in
                try WorkloadFactStore.applyDeliveredView(cached, db: db)
            }
        }
        let stored = try queue.read { try VM.fetchOne($0, key: "app-4") }
        #expect(stored?.specGeneration == 5)
        #expect(stored?.cpuCount == 1)
    }

    @Test func `docker health ignores qemu and requires every service`() {
        let qemu = WorkloadHealthSignals(qemuProcess: true, qmp: true)
        let now = "2026-09-24T00:00:00Z"
        let missing = WorkloadHealthProjector.project(
            state: .running,
            signals: qemu,
            updatedAt: now,
            kind: WorkloadSpec.kindApplication,
            observedAt: now,
            freshness: "fresh",
        )
        #expect(!missing.checks.contains { $0.name == "qemuProcess" || $0.name == "qmp" })
        #expect(missing.condition == "unknown")
        #expect(missing.health != .guestReady)

        let partial = WorkloadHealthProjector.project(
            state: .running,
            signals: .unobserved,
            updatedAt: now,
            kind: WorkloadSpec.kindApplication,
            services: [
                WorkloadServiceObservation(
                    name: "web", role: WorkloadServiceObservation.roleLongRunning,
                    running: true, health: "healthy",
                ),
                WorkloadServiceObservation(
                    name: "worker", role: WorkloadServiceObservation.roleLongRunning,
                    running: false, health: "none",
                ),
            ],
            observedAt: now,
            freshness: "fresh",
            appliedGeneration: 3,
        )
        #expect(partial.running == true)
        #expect(partial.condition == "unhealthy")
        #expect(partial.health == .degraded)
        #expect(partial.checks.contains { $0.name == "service:worker" && $0.status == .fail })

        let ready = WorkloadHealthProjector.project(
            state: .running,
            signals: .unobserved,
            updatedAt: now,
            kind: WorkloadSpec.kindApplication,
            services: [
                WorkloadServiceObservation(
                    name: "migrate", role: WorkloadServiceObservation.roleOneShot,
                    running: false, exitCode: 0, health: "none",
                ),
                WorkloadServiceObservation(
                    name: "web", role: WorkloadServiceObservation.roleLongRunning,
                    running: true, health: "healthy",
                ),
            ],
            observedAt: now,
            freshness: "fresh",
        )
        #expect(ready.condition == "healthy")
        #expect(ready.readiness == "ready")
        #expect(ready.checks.contains { $0.name == "service:migrate" && $0.message == "one-shot succeeded" })

        let failedJob = WorkloadHealthProjector.project(
            state: .running,
            signals: .unobserved,
            updatedAt: now,
            kind: WorkloadSpec.kindApplication,
            services: [
                WorkloadServiceObservation(
                    name: "migrate", role: WorkloadServiceObservation.roleOneShot,
                    running: false, exitCode: 1, health: "none",
                ),
            ],
            observedAt: now,
            freshness: "fresh",
        )
        #expect(failedJob.condition == "unhealthy")
        #expect(failedJob.checks.contains { $0.message == "one-shot exited 1" })
    }

    @Test func `qemu checks stay on virtual machines`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(qemuProcess: true, qmp: true),
            updatedAt: "2026-09-24T00:00:00Z",
            kind: WorkloadSpec.kindVirtualMachine,
            observedAt: "2026-09-24T00:00:00Z",
            freshness: "fresh",
        )
        #expect(status.checks.contains { $0.name == "qemuProcess" && $0.status == .pass })
        #expect(status.running == true)
        #expect(status.readiness == "ready")
        #expect(status.condition == "unknown")
    }

    @Test func `stale observation is distinct from unknown`() {
        let clock = iso8601.date(from: "2026-09-24T02:00:00Z") ?? Date()
        let status = WorkloadHealthProjector.project(
            state: .running,
            updatedAt: "2026-09-24T00:00:00Z",
            now: clock,
            kind: WorkloadSpec.kindApplication,
            observedAt: "2026-09-24T00:00:00Z",
            freshness: "fresh",
        )
        #expect(status.observation == "stale")
        let unknown = WorkloadHealthProjector.project(
            state: .stopped,
            updatedAt: "2026-09-24T00:00:00Z",
            kind: WorkloadSpec.kindVirtualMachine,
        )
        #expect(unknown.observation == "unknown")
    }

    @Test func `accepted resources are written into compose limits or rejected`() throws {
        #expect(throws: BarkVisorError.self) {
            try ComposeResources.validateAccepted(cpu: 1, memoryMb: 64)
        }
        try ComposeResources.validateAccepted(cpu: 0, memoryMb: 0)
        let rendered = try ComposeAllowlist.render(
            yaml: "services:\n  app:\n    image: example/app\n",
            workloadID: "app-limits",
            stateDir: URL(fileURLWithPath: "/tmp/app-limits"),
            acceptedResources: WorkloadResources(cpu: 1, memoryMb: 128),
        )
        #expect(rendered.yaml.contains("cpus:"))
        #expect(rendered.yaml.contains("128M"))
        let replaced = try ComposeAllowlist.render(
            yaml: """
            services:
              app:
                image: example/app
                deploy:
                  resources:
                    limits:
                      cpus: '4'
                      memory: 1G
            """,
            workloadID: "app-replace",
            stateDir: URL(fileURLWithPath: "/tmp/app-replace"),
            acceptedResources: WorkloadResources(cpu: 1, memoryMb: 128),
        )
        #expect(replaced.yaml.contains("128M"))
        #expect(!replaced.yaml.contains("1G"))
    }

    @Test func `inspect reports container health instead of qemu`() {
        let json = Data(#"""
        [{
          "Name": "/bv-app-1-web",
          "Config": {"Labels": {"com.docker.compose.service": "web"}},
          "State": {"Status": "running", "Running": true, "ExitCode": 0, "Health": {"Status": "unhealthy"}},
          "HostConfig": {"NanoCpus": 1000000000, "Memory": 134217728}
        }]
        """#.utf8)
        let services = DockerServiceHealth.observations(
            inspectJSON: json,
            roles: ["web": WorkloadServiceObservation.roleLongRunning],
        )
        let status = WorkloadHealthProjector.project(
            state: .running,
            updatedAt: "2026-09-24T00:00:00Z",
            kind: WorkloadSpec.kindApplication,
            services: services,
            observedAt: "2026-09-24T00:00:00Z",
            freshness: "fresh",
        )
        #expect(status.condition == "unhealthy")
        #expect(!status.checks.contains { $0.name == "qemuProcess" })
        let enforced = DockerServiceHealth.enforcedResources(inspectJSON: json)
        #expect(enforced.cpu == 1)
        #expect(enforced.memoryMb == 128)
    }

    @Test func `migration keeps stored workload fields and seeds an observation`() throws {
        let queue = try DatabaseQueue()
        try migrateThroughM022(queue)
        try queue.write { db in
            var vm = application(id: "kept", generation: 3, cpu: 2, memory: 256)
            vm.startOnBoot = true
            vm.overridesJson = #"{"linux":{"resources":{"cpu":2,"memoryMb":256}}}"#
            vm.gpuDevices = "[]"
            vm.specJson = #"{"apiVersion":"barkvisor.dev/v1","kind":"Application","metadata":{"name":"kept"},"spec":{"resources":{"cpu":2,"memoryMb":256},"env":{"TOKEN":"secret"}}}"#
            try vm.insert(db)
        }
        try queue.write { db in try M023_WorkloadObservations.migrate(db) }
        let stored = try queue.read { db in
            try (
                VM.fetchOne(db, key: "kept"),
                WorkloadObservation.fetchOne(db, key: "kept"),
            )
        }
        let vm = try #require(stored.0)
        #expect(vm.startOnBoot)
        #expect(vm.cpuCount == 2)
        #expect(vm.memoryMb == 256)
        #expect(vm.overridesJson?.contains("linux") == true)
        #expect(vm.gpuDevices == "[]")
        #expect(vm.specJson?.contains("TOKEN") == true)
        #expect(vm.specJson?.contains("secret") == true)
        let observation = try #require(stored.1)
        #expect(observation.appliedGeneration == 3)
        #expect(observation.processState == vm.state)
        #expect(observation.condition == "unknown")
    }

    @Test func `api projections keep both workload kinds compatible`() throws {
        let vm = application(id: "vm-kind", generation: 2, cpu: 2, memory: 1_024)
        var virtual = vm
        virtual.kind = WorkloadSpec.kindVirtualMachine
        virtual.vmType = "linux-arm64"
        let vmResponse = VMResponse(
            from: virtual,
            signals: WorkloadHealthSignals(qemuProcess: true, qmp: true),
            observation: WorkloadObservation(
                id: virtual.id, sequence: 1, appliedGeneration: 2,
                processState: "stopped", readiness: "not_ready", condition: "unknown",
                observedAt: "2026-09-24T00:00:00Z", freshness: "fresh",
            ),
        )
        var app = application(id: "app-kind", generation: 4, cpu: 1, memory: 128)
        app.state = "running"
        let appResponse = VMResponse(
            from: app,
            signals: WorkloadHealthSignals(qemuProcess: true, qmp: true),
            observation: WorkloadObservation(
                id: app.id, sequence: 2, appliedGeneration: 4,
                processState: "running", readiness: "not_ready", condition: "unhealthy",
                observedAt: "2026-09-24T00:00:00Z", freshness: "fresh",
                enforcedCpu: 1, enforcedMemoryMb: 128,
                servicesJson: WorkloadObservation.encodeServices([
                    WorkloadServiceObservation(
                        name: "web", role: WorkloadServiceObservation.roleLongRunning,
                        running: true, health: "unhealthy",
                    ),
                ]),
            ),
        )
        let vmJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(vmResponse)) as? [String: Any]
        let appJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(appResponse)) as? [String: Any]
        let vmStatus = try #require(vmJSON?["status"] as? [String: Any])
        let appStatus = try #require(appJSON?["status"] as? [String: Any])
        #expect(vmJSON?["state"] as? String == "stopped")
        #expect(vmStatus["health"] as? String == "stopped")
        #expect(vmJSON?["kind"] as? String == WorkloadSpec.kindVirtualMachine)
        #expect((vmJSON?["spec"] as? [String: Any]) != nil)
        #expect(appJSON?["kind"] as? String == WorkloadSpec.kindApplication)
        #expect(appStatus["running"] as? Bool == true)
        #expect(appStatus["condition"] as? String == "unhealthy")
        #expect(appStatus["appliedGeneration"] as? Int == 4)
        #expect(appStatus["generation"] as? Int == 4)
        let checks = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(qemuProcess: true, qmp: true),
            updatedAt: app.updatedAt,
            kind: app.kind,
            services: appResponse.status.condition == "unhealthy"
                ? [
                    WorkloadServiceObservation(
                        name: "web", role: WorkloadServiceObservation.roleLongRunning,
                        running: true, health: "unhealthy",
                    ),
                ]
                : [],
            observedAt: "2026-09-24T00:00:00Z",
            freshness: "fresh",
        ).checks
        #expect(!checks.contains { $0.name == "qemuProcess" })
        let event = VMStateEvent(
            id: app.id, state: "running", error: nil,
            running: true, readiness: "not_ready", condition: "unhealthy",
            observation: "fresh", appliedGeneration: 4,
        )
        let eventJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        #expect(eventJSON?["state"] as? String == "running")
        #expect(eventJSON?["condition"] as? String == "unhealthy")
        #expect(eventJSON?["observation"] as? String == "fresh")
        let legacy = try JSONDecoder().decode(
            VMStateEvent.self,
            from: Data(#"{"id":"vm-1","state":"running","error":null}"#.utf8),
        )
        #expect(legacy.condition == nil)
        #expect(legacy.state == "running")
    }

    @Test func `process state write keeps a newer spec`() async throws {
        let pool = try makePool()
        try await insertApplication(pool, id: "app-5", generation: 1, cpu: 1, memory: 128)
        var vm = try #require(try await pool.read { try VM.fetchOne($0, key: "app-5") })
        try await ApplicationLifecycleService.setState(&vm, state: "running", error: nil, db: pool)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE vms SET specGeneration = 2, cpuCount = 8, memoryMb = 2048 WHERE id = 'app-5'",
            )
        }
        var stale = vm
        stale.specGeneration = 1
        stale.cpuCount = 1
        await #expect(throws: BarkVisorError.self) {
            try await ApplicationLifecycleService.setState(&stale, state: "stopped", error: nil, db: pool)
        }
        let stored = try await pool.read { try VM.fetchOne($0, key: "app-5") }
        #expect(stored?.specGeneration == 2)
        #expect(stored?.cpuCount == 8)
        #expect(stored?.state == "running")
        let observation = try await pool.read { try WorkloadObservation.fetchOne($0, key: "app-5") }
        #expect(observation?.appliedGeneration == 1)
    }
}

private func migratedQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try AppDatabase.makeMigrator().migrate(queue)
    return queue
}

private func makePool() throws -> DatabasePool {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("workload-facts-\(UUID().uuidString).sqlite")
    let pool = try DatabasePool(path: url.path)
    try AppDatabase.makeMigrator().migrate(pool)
    return pool
}

private func migrateThroughM022(_ db: DatabaseWriter) throws {
    try db.write { db in
        try M001_CreateSchema.migrate(db)
        try M002_WorkloadSpec.migrate(db)
        try M003_ArchitectureAwareTemplates.migrate(db)
        try M004_WorkloadOverrides.migrate(db)
        try M005_WorkloadHealth.migrate(db)
        try M006_ImageSha256.migrate(db)
        try M007_RepairOrphanAuditFKs.migrate(db)
        try M008_GuestListeningPorts.migrate(db)
        try M009_AuthSessions.migrate(db)
        try M010_WorkloadClass.migrate(db)
        try M011_StartOnBoot.migrate(db)
        try M011_OllamaAPIKeys.migrate(db)
        try M012_UserRoles.migrate(db)
        try M013_CodingAgentSession.migrate(db)
        try M013_GPUPassthrough.migrate(db)
        try M014_OllamaPerHostSettings.migrate(db)
        try M015_Passkeys.migrate(db)
        try M016_PendingDeploys.migrate(db)
        try M017_GuestAddressing.migrate(db)
        try M018_ApplicationWorkloads.migrate(db)
        try M019_AppCatalog.migrate(db)
        try M020_ApplicationImageDigest.migrate(db)
        try M021_BuiltinAppsOrigin.migrate(db)
        try M022_RemoveWorkloadClass.migrate(db)
    }
}

private func application(id: String, generation: Int, cpu: Int, memory: Int) -> VM {
    var vm = VM(
        id: id,
        name: id,
        vmType: WorkloadSpec.applicationGuestType,
        state: "stopped",
        cpuCount: cpu,
        memoryMb: memory,
        bootDiskId: nil,
        kind: WorkloadSpec.kindApplication,
        composeYaml: "services:\n  web:\n    image: example/app\n",
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
        specGeneration: generation,
        startOnBoot: true,
        createdAt: "2026-09-24T00:00:00Z",
        updatedAt: "2026-09-24T00:00:00Z",
    )
    vm.specGeneration = generation
    return vm
}

private func insertApplication(
    _ writer: DatabaseWriter, id: String, generation: Int, cpu: Int, memory: Int,
) throws {
    let vm = application(id: id, generation: generation, cpu: cpu, memory: memory)
    try writer.write { db in try vm.insert(db) }
}

private func insertApplication(
    _ pool: DatabasePool, id: String, generation: Int, cpu: Int, memory: Int,
) async throws {
    let vm = application(id: id, generation: generation, cpu: cpu, memory: memory)
    try await pool.write { db in try vm.insert(db) }
}
