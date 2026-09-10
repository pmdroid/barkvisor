import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
final class ApplicationLifecycleServiceTests {
    @Test func `prepare rewrites published ports onto 0.0.0.0`() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-app-lan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let yaml = """
        services:
          whoami:
            image: traefik/whoami
            ports:
              - "8080:80"
              - "1900:1900/udp"
        """
        let render = try ApplicationLifecycleService.prepare(
            id: "whoami-1",
            composeYaml: yaml,
            env: nil,
            dataDir: dataDir,
        )
        #expect(render.bindHost == "0.0.0.0")
        #expect(render.yaml.contains("0.0.0.0"))
        let written = try String(
            contentsOf: ComposeRuntime.projectDirectory(id: "whoami-1", dataDir: dataDir)
                .appendingPathComponent("compose.yml"),
            encoding: .utf8,
        )
        #expect(written.contains("0.0.0.0"))
        let rules = ApplicationLifecycleService.portRules(render.publishedPorts)
        #expect(rules.contains { $0.protocol == "udp" && $0.hostPort == 1_900 })
        #expect(rules.contains { $0.protocol == "tcp" && $0.hostPort == 8_080 })
    }

    @Test func `prepare without published ports does not require a LAN address`() throws {
        HostInfoService.lanBindIPv4Provider = { nil }
        defer { HostInfoService.lanBindIPv4Provider = nil }
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-app-nolan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let yaml = """
        services:
          worker:
            image: alpine
            command: sleep 3600
        """
        let render = try ApplicationLifecycleService.prepare(
            id: "worker-1",
            composeYaml: yaml,
            env: nil,
            dataDir: dataDir,
        )
        #expect(render.publishedPorts.isEmpty)
        #expect(render.bindHost.isEmpty)
    }

    @Test func `prepare with published ports does not require a LAN address`() throws {
        HostInfoService.lanBindIPv4Provider = { nil }
        defer { HostInfoService.lanBindIPv4Provider = nil }
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-app-needslan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let yaml = """
        services:
          whoami:
            image: traefik/whoami
            ports:
              - "8080:80"
        """
        let render = try ApplicationLifecycleService.prepare(
            id: "whoami-nolan",
            composeYaml: yaml,
            env: nil,
            dataDir: dataDir,
        )
        #expect(render.bindHost == "0.0.0.0")
        #expect(render.publishedPorts.contains { $0.hostPort == 8_080 })
    }

    @Test func `inspect wildcard HostIp is accepted`() async throws {
        let data = Data(
            """
            [{"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}}}]
            """.utf8,
        )
        try await DockerInspectTestGate.withStub({ _ in data }) {
            try ApplicationLifecycleService.verifyInspectedBinds(
                containerNames: ["bv-whoami-1-whoami"],
                bindHost: "0.0.0.0",
                expected: [PublishedPort(hostPort: 8_080, containerPort: 80, proto: "tcp")],
            )
        }
    }

    @Test func `restart inspect failure releases PortRegistry claims`() async throws {
        HostInfoService.lanBindIPv4Provider = { "192.168.8.10" }
        DockerEngine.snapshotProvider = {
            DockerEngineSnapshot(
                os: "Linux",
                dockerPath: "/usr/bin/docker",
                dockerVersion: "27.0.0",
                daemonRunning: true,
                composeVersion: "Docker Compose version v2.29.7",
                composeOK: true,
            )
        }
        ComposeRuntime.runner = SucceedingComposeRunner()
        defer {
            HostInfoService.lanBindIPv4Provider = nil
            DockerEngine.snapshotProvider = { DockerEngine.liveSnapshot() }
            ComposeRuntime.runner = LiveComposeCommandRunner()
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(db)

        var vm = applicationVM(id: "whoami-restart")
        vm.composeYaml = """
        services:
          whoami:
            image: traefik/whoami
            ports:
              - "58080:80"
              - "51900:1900/udp"
        """
        let seed = vm
        try await db.write { db in try seed.insert(db) }

        let inspect = RestartInspect()
        try await DockerInspectTestGate.withStub({ names in
            try inspect.data(for: names)
        }) {
            try await ApplicationLifecycleService.start(vm: &vm, db: db, dataDir: tmp)
            let afterStart = try await db.read { db in try PortRegistry.claims(db: db) }
            #expect(afterStart.contains { $0.hostPort == 58_080 && $0.workloadId == "whoami-restart" })
            #expect(afterStart.contains { $0.hostPort == 51_900 && $0.proto == "udp" })

            inspect.fail = true
            do {
                try await ApplicationLifecycleService.restart(vm: &vm, db: db, dataDir: tmp)
                Issue.record("expected restart inspect failure")
            } catch {
                if let stored = try await db.read({ db in
                    try VM.fetchOne(db, key: "whoami-restart")
                }) {
                    vm = stored
                } else {
                    Issue.record("whoami-restart row missing after restart failure")
                }
                let claims = try await db.read { db in try PortRegistry.claims(db: db) }
                #expect(!claims.contains { $0.hostPort == 58_080 && $0.workloadId == "whoami-restart" })
                #expect(!claims.contains { $0.hostPort == 51_900 && $0.workloadId == "whoami-restart" })
                #expect(vm.decodedPortForwards.isEmpty)
                try await PortRegistry.assertAvailable(
                    [PortForwardRule(protocol: "tcp", hostPort: 58_080, guestPort: 80)],
                    db: db,
                )
            }
        }
    }

    @Test func `down removes the project when compose fails`() async throws {
        let previous = ComposeRuntime.runner
        ComposeRuntime.runner = FailingComposeRunner()
        defer { ComposeRuntime.runner = previous }

        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-app-down-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let id = "app-delete"
        let dir = ComposeRuntime.projectDirectory(id: id, dataDir: dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "services: {}\n".write(
            to: dir.appendingPathComponent("compose.yml"),
            atomically: true,
            encoding: .utf8,
        )

        await ApplicationLifecycleService.down(vm: applicationVM(id: id), dataDir: dataDir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func `reconcile writes docker state while the daemon stays up`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(db)

        var vm = applicationVM(id: "whoami-live")
        vm.state = "running"
        let seed = vm
        try await db.write { db in try seed.insert(db) }

        ComposeRuntime.labeledStatesProvider = { ["whoami-live": "stopped"] }
        defer { ComposeRuntime.labeledStatesProvider = nil }

        await ApplicationLifecycleService.reconcile(db: db, dataDir: tmp)
        let state = try await db.read { db in try VM.fetchOne(db, key: "whoami-live")?.state }
        #expect(state == "stopped")
    }

    @Test func `start refuses a deleting application`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(db)

        var vm = applicationVM(id: "whoami-del")
        vm.state = "deleting"
        let seed = vm
        try await db.write { db in try seed.insert(db) }

        let error = await #expect(throws: BarkVisorError.self) {
            try await ApplicationLifecycleService.start(vm: &vm, db: db, dataDir: tmp)
        }
        guard case let .conflict(message) = error else {
            Issue.record("expected conflict")
            return
        }
        #expect(message == "Workload is deleting")
        let state = try await db.read { db in try VM.fetchOne(db, key: "whoami-del")?.state }
        #expect(state == "deleting")
    }
}

private func applicationVM(id: String) -> VM {
    VM(
        id: id,
        name: id,
        vmType: WorkloadSpec.applicationGuestType,
        state: "error",
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

private final class RestartInspect: @unchecked Sendable {
    var fail = false

    func data(for names: [String]) throws -> Data {
        if fail { return Data("[]".utf8) }
        let ports: [String: Any] = [
            "80/tcp": [["HostIp": "192.168.8.10", "HostPort": "58080"]],
            "1900/udp": [["HostIp": "192.168.8.10", "HostPort": "51900"]],
        ]
        let objects: [[String: Any]] = names.map { _ in
            ["NetworkSettings": ["Ports": ports]]
        }
        return try JSONSerialization.data(withJSONObject: objects)
    }
}

private struct SucceedingComposeRunner: ComposeCommandRunning {
    func run(
        arguments: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        if arguments.contains("ps") {
            return CommandResult(
                exitCode: 0,
                stdout: Data(#"[{"State":"running"}]"#.utf8),
                stderr: Data(),
            )
        }
        return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private struct FailingComposeRunner: ComposeCommandRunning {
    func run(
        arguments _: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        CommandResult(
            exitCode: 1,
            stdout: Data(),
            stderr: Data("docker compose: Cannot connect to the Docker daemon".utf8),
        )
    }
}
