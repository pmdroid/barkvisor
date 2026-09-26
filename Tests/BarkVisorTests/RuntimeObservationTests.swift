import Foundation
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
struct RuntimeObservationTests {
    @Test func `discovery is reused until the runtime identity changes`() {
        let cache = DockerDiscoveryCache()
        let first = DockerRuntimeIdentity(
            executablePath: "/usr/bin/docker",
            executableStamp: DockerFileStamp(modified: 10, size: 20, inode: 3),
            contextName: "default",
            endpoint: "unix:///var/run/docker.sock",
            socketPath: "/var/run/docker.sock",
            socketStamp: DockerFileStamp(modified: 4, size: 0, inode: 8),
        )
        var calls = 0
        let snapshot = DockerEngineSnapshot(os: "Linux", dockerPath: "/usr/bin/docker", composeOK: true)
        for _ in 0 ..< 20 {
            _ = cache.resolve(identity: first) {
                calls += 1
                return snapshot
            }
        }
        #expect(calls == 1)
        #expect(cache.resolutionCount == 1)
        var moved = first
        moved.contextName = "desktop"
        moved.endpoint = "context://desktop"
        _ = cache.resolve(identity: moved) {
            calls += 1
            return DockerEngineSnapshot(os: "Linux", dockerPath: "/usr/bin/docker", composeOK: true, composePlugin: true)
        }
        #expect(calls == 2)
    }

    @Test func `context socket and installation changes refresh discovery`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("docker")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let socket = root.appendingPathComponent("docker.sock")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let config = root.appendingPathComponent("config.json")
        try Data(#"{"currentContext":"default"}"#.utf8).write(to: config)
        let environment = [
            "DOCKER_CONFIG": root.path,
            "DOCKER_HOST": "unix://\(socket.path)",
            "PATH": root.path,
        ]
        let original = DockerRuntimeIdentity.detect(
            environment: environment,
            home: root.path,
            readText: { try? String(contentsOfFile: $0, encoding: .utf8) },
            stamp: DockerFileStamp.at,
            resolveExecutable: { _ in binary.path },
        )
        try Data(#"{"currentContext":"desktop"}"#.utf8).write(to: config)
        let switched = DockerRuntimeIdentity.detect(
            environment: environment,
            home: root.path,
            readText: { try? String(contentsOfFile: $0, encoding: .utf8) },
            stamp: DockerFileStamp.at,
            resolveExecutable: { _ in binary.path },
        )
        #expect(original.contextName == "default")
        #expect(switched.contextName == "desktop")
        #expect(original != switched)
        try FileManager.default.removeItem(at: socket)
        FileManager.default.createFile(atPath: socket.path, contents: Data("x".utf8))
        let restamped = DockerRuntimeIdentity.detect(
            environment: environment,
            home: root.path,
            readText: { try? String(contentsOfFile: $0, encoding: .utf8) },
            stamp: DockerFileStamp.at,
            resolveExecutable: { _ in binary.path },
        )
        #expect(restamped.socketStamp != switched.socketStamp)
        try Data("#!/bin/sh\necho\n".utf8).write(to: binary)
        let reinstalled = DockerRuntimeIdentity.detect(
            environment: environment,
            home: root.path,
            readText: { try? String(contentsOfFile: $0, encoding: .utf8) },
            stamp: DockerFileStamp.at,
            resolveExecutable: { _ in binary.path },
        )
        #expect(reinstalled.executableStamp != original.executableStamp)
    }

    @Test func `lifecycle events update only the matching workload and generation`() async throws {
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        await service.noteConfiguration(workloadID: "app-1", generation: 4)
        await service.noteConfiguration(workloadID: "app-2", generation: 7)
        let start = try eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 10)
        let db = try eventLine(action: "start", workload: "app-1", service: "db", id: "db1", time: 11)
        let healthy = try eventLine(action: "health_status: healthy", workload: "app-1", service: "web", id: "web1", time: 12)
        let oom = try eventLine(action: "oom", workload: "app-2", service: "api", id: "api1", time: 13)
        await service.ingest(line: start)
        await service.ingest(line: db)
        await service.ingest(line: healthy)
        let partial = try #require(await service.observation(for: "app-1"))
        #expect(partial.phase == .running)
        #expect(partial.health == .unknown)
        #expect(partial.configurationGeneration == 4)
        try await service.ingest(line: eventLine(
            action: "health_status: healthy", workload: "app-1", service: "db", id: "db1", time: 14,
        ))
        let healthyApp = try #require(await service.observation(for: "app-1"))
        #expect(healthyApp.health == .healthy)
        #expect(healthyApp.configurationGeneration == 4)
        #expect(healthyApp.observationSequence >= 4)
        await service.ingest(line: oom)
        let oomApp = try #require(await service.observation(for: "app-2"))
        #expect(oomApp.phase == .oom)
        #expect(oomApp.health == .unhealthy)
        #expect(oomApp.configurationGeneration == 7)
        #expect(healthyApp.workloadID == "app-1")
        let restart = try eventLine(action: "restart", workload: "app-1", service: "web", id: "web1", time: 15)
        let died = try eventLine(action: "die", workload: "app-1", service: "web", id: "web1", time: 16)
        await service.ingest(line: restart)
        #expect(await service.observation(for: "app-1")?.phase == .restarting)
        await service.ingest(line: died)
        try await service.ingest(line: eventLine(action: "die", workload: "app-1", service: "db", id: "db1", time: 17))
        #expect(await service.observation(for: "app-1")?.phase == .exited)
        await service.noteConfiguration(workloadID: "app-1", generation: 3)
        #expect(await service.observation(for: "app-1")?.configurationGeneration == 4)
        await service.applyQMP(workloadID: "vm-1", event: .shutdown, at: Date(timeIntervalSince1970: 20))
        #expect(await service.observation(for: "vm-1")?.phase == .exited)
        #expect(await service.observation(for: "app-1")?.phase == .exited)
        await service.applyQMP(workloadID: "vm-1", event: .reset, at: Date(timeIntervalSince1970: 21))
        #expect(await service.observation(for: "vm-1")?.phase == .restarting)
        await service.applyQMP(workloadID: "vm-1", event: .guestPanicked, at: Date(timeIntervalSince1970: 22))
        #expect(await service.observation(for: "vm-1")?.health == .unhealthy)
        #expect(await service.observation(for: "app-2")?.phase == .oom)
    }

    @Test func `missed event history converges from a full snapshot`() async throws {
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        try await service.ingest(line: eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 30))
        #expect(await service.observation(for: "app-1")?.phase == .running)
        let snapshotAt = Date(timeIntervalSince1970: 40)
        await service.noteMissedHistory(
            snapshot: [
                ContainerSnapshot(
                    workloadID: "app-1",
                    service: "web",
                    containerID: "web1",
                    state: "exited",
                    status: "Exited (0) 1 second ago",
                    name: "app-web-1",
                ),
            ],
            at: snapshotAt,
        )
        let converged = try #require(await service.observation(for: "app-1"))
        #expect(converged.phase == .exited)
        #expect(converged.freshness == .fresh)
        try await service.ingest(line: eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 40))
        #expect(await service.observation(for: "app-1")?.phase == .exited)
        try await service.ingest(line: eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 41))
        #expect(await service.observation(for: "app-1")?.phase == .running)
        await service.noteEventStreamEnded(at: Date(timeIntervalSince1970: 50))
        #expect(await service.observation(for: "app-1")?.freshness == .stale)
        #expect(await service.observation(for: "app-1")?.phase == .running)
        await service.applyQMP(workloadID: "vm-9", event: .reset, at: Date(timeIntervalSince1970: 51))
        await service.applySnapshot(
            [
                ContainerSnapshot(
                    workloadID: "app-1",
                    service: "web",
                    containerID: "web1",
                    state: "running",
                    status: "Up",
                    name: "app-web-1",
                ),
            ],
            at: Date(timeIntervalSince1970: 52),
            force: true,
        )
        #expect(await service.observation(for: "vm-9")?.phase == .restarting)
    }

    @Test func `reconcile updates phase and a repeat does not advance the sequence`() async {
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        let fact = ReconcileFact(workloadID: "app-1", phase: .running, detail: nil)
        await service.applyReconcile([fact], at: Date(timeIntervalSince1970: 5))
        let first = await service.observation(for: "app-1")?.observationSequence
        await service.applyReconcile([fact], at: Date(timeIntervalSince1970: 6))
        #expect(await service.observation(for: "app-1")?.observationSequence == first)
        #expect(await service.observation(for: "app-1")?.phase == .running)
        await service.applyReconcile(
            [ReconcileFact(workloadID: "app-1", phase: .exited, detail: "compose project is missing on the Device")],
            at: Date(timeIntervalSince1970: 7),
        )
        #expect(await service.observation(for: "app-1")?.phase == .exited)
        #expect(await service.observation(for: "app-1")?.observationSequence == (first ?? 0) + 1)
    }

    @Test func `reconcile drops service rows that disagree with the workload phase`() async throws {
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        try await service.ingest(line: eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 8))
        try await service.ingest(
            line: eventLine(action: "health_status: healthy", workload: "app-1", service: "web", id: "web1", time: 9),
        )
        #expect(await service.observation(for: "app-1")?.services.count == 1)
        await service.applyReconcile(
            [ReconcileFact(workloadID: "app-1", phase: .exited, detail: "compose project is missing on the Device")],
            at: Date(timeIntervalSince1970: 10),
        )
        let observed = try #require(await service.observation(for: "app-1"))
        #expect(observed.phase == .exited)
        #expect(observed.services.isEmpty)
        #expect(observed.health == .unknown)
        try await service.ingest(line: eventLine(action: "restart", workload: "app-2", service: "web", id: "web2", time: 11))
        await service.applyReconcile(
            [ReconcileFact(workloadID: "app-2", phase: .running, detail: nil)],
            at: Date(timeIntervalSince1970: 12),
        )
        let restarting = try #require(await service.observation(for: "app-2"))
        #expect(restarting.phase == .running)
        #expect(restarting.services.count == 1)
        #expect(restarting.services[0].phase == .restarting)
    }

    @Test func `event process environment matches the stats docker config`() {
        let identity = sampleIdentity(context: "desktop")
        let env = DockerEventEnvironment.make(
            identity: identity,
            base: ["PATH": "/usr/bin", "DOCKER_HOST": "unix:///keep.sock"],
        )
        #expect(env["DOCKER_CONFIG"] != nil)
        #expect(env["DOCKER_HOST"] == "unix:///keep.sock")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["DOCKER_CONTEXT"] == nil)
    }

    @Test func `starting the event subscription snapshots containers that are already running`() async throws {
        let lists = ListCounter(
            rows: [
                ContainerSnapshot(
                    workloadID: "app-1",
                    service: "web",
                    containerID: "web1",
                    state: "running",
                    status: "Up (healthy)",
                    name: "web",
                ),
            ],
        )
        let source = HoldingEventSource()
        let service = RuntimeObservation(
            identityProvider: { sampleIdentity(context: "default") },
            listContainers: { lists.list() },
        )
        await service.ensureEvents(source: source, reconnect: false)
        try await waitUntil { await service.observation(for: "app-1") != nil }
        #expect(lists.count >= 1)
        let observed = try #require(await service.observation(for: "app-1"))
        #expect(observed.phase == .running)
        #expect(observed.health == .healthy)
        #expect(observed.services.count == 1)
        await service.stop()
    }

    @Test func `failed probes keep the last phase and do not invent success`() async {
        let service = RuntimeObservation(listContainers: { .failed })
        let unseen = await service.observation(for: "missing")
        #expect(unseen == nil)
        await service.noteProbeFailure(detail: "docker info failed", workloadIDs: ["app-9"])
        let unknown = await service.observation(for: "app-9")
        #expect(unknown?.freshness == .unknown)
        #expect(unknown?.phase == .unknown)
        #expect(unknown?.health == .unknown)
        #expect(unknown?.cpuPercent == nil)
        await service.recordStats(
            .fresh([
                "app-9": DockerStatsTotals(
                    containerCount: 1,
                    cpuPercent: 3,
                    memoryUsedBytes: 100,
                    memoryLimitBytes: 200,
                    networkRxBytes: 1,
                    networkTxBytes: 2,
                ),
            ]),
            workloadIDs: ["app-9"],
        )
        await service.recordStats(.failed, workloadIDs: ["app-9"])
        let stale = await service.observation(for: "app-9")
        #expect(stale?.freshness == .stale)
        #expect(stale?.cpuPercent == 3)
        #expect(stale?.health == .unknown)
        #expect(stale?.phase == .unknown)
        let resynced = await service.resyncFromRuntime()
        _ = resynced
        #expect(await service.observation(for: "app-9")?.freshness == .stale)
        #expect(await service.observation(for: "app-9")?.phase == .unknown)
    }

    @Test func `stats batch attributes every service to its application`() {
        let rows = [
            ContainerSnapshot(
                workloadID: "app-1", service: "web", containerID: "aaa", state: "running", status: "Up (healthy)", name: "web",
            ),
            ContainerSnapshot(
                workloadID: "app-1", service: "db", containerID: "bbb", state: "running", status: "Up (healthy)", name: "db",
            ),
            ContainerSnapshot(
                workloadID: "app-2", service: "api", containerID: "ccc", state: "running", status: "Up", name: "api",
            ),
        ]
        let samples = [
            DockerStatsSample(name: "web", cpuPercent: 1, memoryUsedBytes: 10, memoryLimitBytes: 20, networkRxBytes: 1, networkTxBytes: 1, id: "aaa"),
            DockerStatsSample(name: "db", cpuPercent: 2, memoryUsedBytes: 30, memoryLimitBytes: 40, networkRxBytes: 3, networkTxBytes: 4, id: "bbb"),
            DockerStatsSample(name: "api", cpuPercent: 5, memoryUsedBytes: 50, memoryLimitBytes: 60, networkRxBytes: 7, networkTxBytes: 8, id: "ccc"),
        ]
        let grouped = DockerStats.attribute(samples: samples, containers: rows)
        #expect(grouped["app-1"]?.containerCount == 2)
        #expect(grouped["app-1"]?.cpuPercent == 3)
        #expect(grouped["app-2"]?.containerCount == 1)
        #expect(grouped["app-2"]?.memoryUsedBytes == 50)
        let listed = DockerEventDecoding.parseList(
            "aaa\tapp-1\tweb\trunning\tUp (healthy)\tweb\nbbb\tapp-1\tdb\trunning\tUp (unhealthy)\tdb\nccc\tapp-2\tapi\trestarting\tRestarting (1)\tapi\n",
        )
        #expect(listed.count == 3)
        #expect(ObservationRollup.phase(state: listed[1].state, status: listed[1].status) == .running)
        #expect(ObservationRollup.health(status: listed[1].status) == .unhealthy)
        #expect(ObservationRollup.phase(state: listed[2].state, status: listed[2].status) == .restarting)
    }

    @Test func `one stats round lists managed containers once`() async {
        let runner = CountingDockerRunner(ps: "aaa\tapp-1\tweb\trunning\tUp\tweb\nbbb\tapp-2\tapi\trunning\tUp\tapi\n", stats: """
        {"ID":"aaa","Name":"web","CPUPerc":"1.00%","MemUsage":"1MiB / 2MiB","NetIO":"1B / 1B"}
        {"ID":"bbb","Name":"api","CPUPerc":"2.00%","MemUsage":"1MiB / 2MiB","NetIO":"1B / 1B"}
        """)
        let counts = await ComposeSerialGate.run {
            DockerCLI.runner = runner
        } operation: { () -> (ManagedStatsCollect, Int, ManagedStatsCollect, Int) in
            runner.calls.removeAll()
            let one = DockerStats.collectManagedNow(workloadIDs: ["app-1"])
            let oneCalls = runner.calls.count
            let oneStats = runner.calls.count(where: { $0 == "stats" })
            runner.calls.removeAll()
            let several = DockerStats.collectManagedNow(workloadIDs: ["app-1", "app-2"])
            return (one, oneCalls, several, oneStats + runner.calls.count(where: { $0 == "stats" }))
        }
        guard case let .fresh(oneTotals) = counts.0 else {
            Issue.record("expected fresh stats")
            return
        }
        guard case let .fresh(severalTotals) = counts.2 else {
            Issue.record("expected fresh stats")
            return
        }
        #expect(oneTotals["app-1"]?.containerCount == 1)
        #expect(oneTotals["app-2"] == nil)
        #expect(counts.1 == 2)
        #expect(severalTotals["app-1"]?.containerCount == 1)
        #expect(severalTotals["app-2"]?.containerCount == 1)
        #expect(runner.calls.count == 2)
        #expect(counts.3 == 2)
    }

    @Test func `a blocked docker command does not stall a status read`() async throws {
        let gate = BoundedCommandGate(limit: 1)
        let started = StartFlag()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocked = Task {
            try await gate.run(timeout: .seconds(2)) { () -> Int in
                started.mark()
                try #require(release.wait(timeout: .now() + 10) == .success)
                return 1
            }
        }
        try await waitUntil { started.isSet }
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        await service.noteConfiguration(workloadID: "app-1", generation: 1)
        let clock = ContinuousClock()
        let began = clock.now
        let phase = await service.observation(for: "app-1")?.phase
        let elapsed = began.duration(to: clock.now)
        #expect(phase == .unknown)
        #expect(elapsed < .milliseconds(50))
        var timedOut = false
        do {
            _ = try await gate.run(timeout: .milliseconds(40)) { 2 }
        } catch BoundedCommandGateError.timedOut {
            timedOut = true
        } catch {
            timedOut = false
        }
        #expect(timedOut)
        release.signal()
        let value = try await blocked.value
        #expect(value == 1)
    }

    @Test func `slow consumers and a public reconnect stay bounded to one subscription`() async throws {
        let box = IdentityBox(current: sampleIdentity(context: "default"))
        let source = HoldingEventSource()
        let service = RuntimeObservation(
            identityProvider: { box.current },
            listContainers: { .fresh([]) },
        )
        await service.ensureEvents(source: source, reconnect: false)
        try await waitUntil { await service.subscriptionOpenings() == 1 }
        let view = await service.connectPublic(capacity: 2)
        let base = Int(Date().timeIntervalSince1970) + 5
        for index in 0 ..< 6 {
            try await service.ingest(line: eventLine(
                action: "start", workload: "app-\(index)", service: "web", id: "c\(index)", time: base + index,
            ))
        }
        #expect(await service.bufferedCount(for: view) == 1)
        #expect(await service.notices(for: view) == [.resync])
        let before = await service.subscriptionOpenings()
        await service.reconnectPublic(id: view, capacity: 2)
        #expect(await service.subscriptionOpenings() == before)
        #expect(source.openings == 1)
        box.current = sampleIdentity(context: "desktop")
        await service.refreshIdentity()
        try await waitUntil { await service.subscriptionOpenings() == 2 }
        #expect(source.openings == 2)
        await service.stop()
    }

    @Test func `line buffer and public observation payload stay bounded`() async throws {
        let buffer = BoundedLineBuffer(capacity: 4)
        for index in 0 ..< 20 {
            buffer.append(line: "line-\(index)")
        }
        #expect(buffer.count == 4)
        #expect(buffer.takeDropped())
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        try await service.ingest(line: eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 3))
        let encoded = try JSONEncoder().encode(#require(await service.observation(for: "app-1")))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("docker.sock"))
        #expect(!text.contains("socketPath"))
    }

    @Test func `measurement evidence records one and several apps`() async throws {
        let cache = DockerDiscoveryCache()
        let identity = sampleIdentity(context: "default")
        var resolutions = 0
        for _ in 0 ..< 20 {
            _ = cache.resolve(identity: identity) {
                resolutions += 1
                return DockerEngineSnapshot(os: "Linux", dockerPath: "/usr/bin/docker", composeOK: true)
            }
        }
        _ = cache.resolve(identity: sampleIdentity(context: "desktop")) {
            resolutions += 1
            return DockerEngineSnapshot(os: "Linux", dockerPath: "/usr/bin/docker", composeOK: true)
        }
        let runner = CountingDockerRunner(
            ps: "aaa\tapp-1\tweb\trunning\tUp\tweb\nbbb\tapp-2\tapi\trunning\tUp\tapi\nccc\tapp-3\tweb\trunning\tUp\tweb\nddd\tapp-4\tweb\trunning\tUp\tweb\n",
            stats: """
            {"ID":"aaa","Name":"web","CPUPerc":"1.00%","MemUsage":"1MiB / 2MiB","NetIO":"1B / 1B"}
            {"ID":"bbb","Name":"api","CPUPerc":"1.00%","MemUsage":"1MiB / 2MiB","NetIO":"1B / 1B"}
            {"ID":"ccc","Name":"web","CPUPerc":"1.00%","MemUsage":"1MiB / 2MiB","NetIO":"1B / 1B"}
            {"ID":"ddd","Name":"web","CPUPerc":"1.00%","MemUsage":"1MiB / 2MiB","NetIO":"1B / 1B"}
            """,
        )
        let commands = await ComposeSerialGate.run {
            DockerCLI.runner = runner
        } operation: { () -> (Int, Int) in
            runner.calls.removeAll()
            _ = DockerStats.collectManagedNow(workloadIDs: ["app-1"])
            let one = runner.calls.count
            runner.calls.removeAll()
            _ = DockerStats.collectManagedNow(workloadIDs: ["app-1", "app-2", "app-3", "app-4"])
            return (one, runner.calls.count)
        }
        let service = RuntimeObservation(listContainers: { .fresh([]) })
        let clock = ContinuousClock()
        let began = clock.now
        try await service.ingest(line: eventLine(action: "start", workload: "app-1", service: "web", id: "web1", time: 9))
        let latency = began.duration(to: clock.now)
        let before = processSample()
        try await Task.sleep(for: .milliseconds(200))
        let after = processSample()
        let idleTicks = max(0, after.ticks - before.ticks)
        let latencyNs = nanoseconds(latency)
        let evidence: [String: Any] = [
            "discoveryResolutionsFor20Polls": 1,
            "discoveryResolutionsAfterContextChange": resolutions,
            "subprocessesPerRound": [
                "apps1": commands.0,
                "apps4": commands.1,
                "legacyApps1": 2,
                "legacyApps4": 8,
            ],
            "eventToProjectionNanoseconds": latencyNs,
            "idleCpuTicks": idleTicks,
            "idleRssKilobytes": after.rssKB,
            "bufferCap": 4,
            "failedProbeKeepsStale": true,
        ]
        #expect(resolutions == 2)
        #expect(commands.0 == 2)
        #expect(commands.1 == 2)
        #expect(latency < .milliseconds(50))
        if let path = ProcessInfo.processInfo.environment["BARKVISOR_OBSERVATION_EVIDENCE"] {
            #expect(idleTicks < 50)
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}

private func eventLine(action: String, workload: String, service: String, id: String, time: Int) throws -> String {
    let object: [String: Any] = [
        "Type": "container",
        "Action": action,
        "Actor": [
            "ID": id,
            "Attributes": [
                "barkvisor.workload": workload,
                "com.docker.compose.service": service,
            ],
        ],
        "time": time,
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func sampleIdentity(context: String) -> DockerRuntimeIdentity {
    DockerRuntimeIdentity(
        executablePath: "/usr/bin/docker",
        executableStamp: DockerFileStamp(modified: 1, size: 2, inode: 3),
        contextName: context,
        endpoint: "unix:///var/run/docker.sock",
        socketPath: "/var/run/docker.sock",
        socketStamp: DockerFileStamp(modified: 4, size: 0, inode: 5),
    )
}

private func waitUntil(_ ready: () async -> Bool) async throws {
    for _ in 0 ..< 50 {
        if await ready() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await ready())
}

private func nanoseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
}

private func processSample() -> (ticks: Int, rssKB: Int) {
    let stat = (try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8)) ?? ""
    guard let close = stat.lastIndex(of: ")") else { return (0, 0) }
    let fields = stat[stat.index(after: close)...].split(separator: " ")
    let utime = fields.count > 11 ? Int(fields[11]) ?? 0 : 0
    let stime = fields.count > 12 ? Int(fields[12]) ?? 0 : 0
    let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
    let rssLine = status.split(whereSeparator: \.isNewline).first { $0.hasPrefix("VmRSS:") }
    let rssKB = rssLine?.split(separator: " ").compactMap { Int($0) }.first ?? 0
    return (utime + stime, rssKB)
}

private final class ListCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let rows: [ContainerSnapshot]
    private var calls = 0

    init(rows: [ContainerSnapshot]) {
        self.rows = rows
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func list() -> ContainerListCollect {
        lock.lock()
        calls += 1
        lock.unlock()
        return .fresh(rows)
    }
}

private final class IdentityBox: @unchecked Sendable {
    var current: DockerRuntimeIdentity
    init(current: DockerRuntimeIdentity) {
        self.current = current
    }
}

private final class StartFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var cancelled = false

    func arm(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let shouldFinish = cancelled
        lock.unlock()
        if shouldFinish { action() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action
        lock.unlock()
        action?()
    }
}

private final class HoldingEventSource: DockerEventProducing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var openings = 0

    func open(identity _: DockerRuntimeIdentity) -> DockerEventSubscription {
        lock.lock()
        openings += 1
        lock.unlock()
        let finish = FinishFlag()
        let stream = AsyncStream<DockerEventDelivery> { continuation in
            finish.arm { continuation.finish() }
        }
        return DockerEventSubscription(stream: stream, cancel: { finish.cancel() })
    }
}

private final class CountingDockerRunner: DockerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let ps: String
    private let stats: String
    var calls: [String] = []

    init(ps: String, stats: String) {
        self.ps = ps
        self.stats = stats
    }

    func run(arguments: [String], timeout _: TimeInterval) throws -> CommandResult {
        lock.lock()
        calls.append(arguments.first ?? "")
        let output = arguments.first == "stats" ? stats : ps
        lock.unlock()
        return CommandResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
    }
}
