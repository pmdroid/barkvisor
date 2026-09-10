import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
final class ApplicationUpdateKeepVolumesTests {
    private let dbPool: DatabasePool
    private let dataDir: URL
    private let runner: RecordingComposeRunner
    private let docker: RecordingDockerRunner

    init() throws {
        ComposeTestIsolation.lock.lock()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dataDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
        runner = RecordingComposeRunner()
        docker = RecordingDockerRunner()
    }

    deinit {
        DockerEngine.snapshotProvider = { DockerEngine.liveSnapshot() }
        ComposeRuntime.runner = LiveComposeCommandRunner()
        DockerCLI.runner = LiveDockerCommandRunner()
        DockerInspect.jsonForContainers = DockerInspect.liveJSON
        try? FileManager.default.removeItem(at: dataDir)
        ComposeTestIsolation.lock.unlock()
    }

    private func withStubs<T>(_ body: () async throws -> T) async throws -> T {
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
        ComposeRuntime.runner = runner
        DockerCLI.runner = docker
        let inspectJSON: @Sendable ([String]) throws -> Data = { _ in Data("[]".utf8) }
        DockerInspect.jsonForContainers = inspectJSON
        return try await ComposeRuntime.$runnerOverride.withValue(runner) {
            try await DockerCLI.$runnerOverride.withValue(docker) {
                try await DockerInspect.$jsonOverride.withValue(inspectJSON) {
                    try await body()
                }
            }
        }
    }

    @Test func `prepare records volume roots under the workload dir`() async throws {
        try await withStubs {
            var vm = try await insertApp()
            let yaml = vm.composeYaml ?? ""
            let render = try ApplicationLifecycleService.prepare(
                id: vm.id,
                composeYaml: yaml,
                env: nil,
                dataDir: dataDir,
            )
            try await ApplicationLifecycleService.start(vm: &vm, db: dbPool, dataDir: dataDir)
            let id = vm.id
            let live = try await dbPool.read { db in try VM.fetchOne(db, key: id) }
            let roots = live?.decodedVolumeRoots ?? []
            let root = ComposeRuntime.projectDirectory(id: vm.id, dataDir: dataDir).path
            #expect(roots.contains(root))
            #expect(roots.contains(root + "/volumes/config"))
            #expect(render.namedVolumes == ["config"])
            #expect(live?.imageRef == "lscr.io/linuxserver/qbittorrent:latest")
            #expect(live?.digest == "sha256:aaa111bbb222")
        }
    }

    @Test func `update pulls then ups and does not down volumes`() async throws {
        try await withStubs {
            var vm = try await insertApp()
            docker.inspectDigest = "sha256:bbb222ccc333"
            docker.manifestDigest = "sha256:bbb222ccc333"
            try await ApplicationLifecycleService.updateImages(vm: &vm, db: dbPool, dataDir: dataDir)
            let joined = runner.calls.map { $0.joined(separator: " ") }
            #expect(joined.contains { $0.contains("pull") })
            #expect(joined.contains { $0.contains("up -d") })
            #expect(!joined.contains { $0.contains("down") })
            let updatedID = vm.id
            let live = try await dbPool.read { db in try VM.fetchOne(db, key: updatedID) }
            #expect(live?.digest == "sha256:bbb222ccc333")
            #expect(live?.catalogDigest == "sha256:bbb222ccc333")
            #expect(live?.updateAvailable == false)
        }
    }

    @Test func `older catalog digest is update available`() async throws {
        try await withStubs {
            var vm = try await insertApp()
            docker.inspectDigest = "sha256:aaa111bbb222"
            docker.manifestDigest = "sha256:fff999eee888"
            try await ApplicationLifecycleService.refreshImageFacts(vm: &vm, db: dbPool, dataDir: dataDir)
            #expect(vm.updateAvailable)
            #expect(vm.catalogDigest == "sha256:fff999eee888")
            #expect(vm.digest == "sha256:aaa111bbb222")
        }
    }

    @Test func `compose logs snapshot returns compose output`() async throws {
        try await withStubs {
            runner.calls = []
            runner.logText = """
            qbittorrent  | The WebUI administrator password was not set. A temporary password is provided for this session: helloQB
            jellyfin  | listening
            """
            let vm = try await insertApp()
            let text = try ApplicationLifecycleService.logs(vm: vm, dataDir: dataDir)
            #expect(text.contains("helloQB"))
            #expect(ComposeLogHints.firstPassword(in: text) == "helloQB")
            #expect(runner.calls.contains { $0.contains("logs") && $0.contains("--tail") })
            #expect(!runner.calls.contains { call in
                guard let i = call.firstIndex(of: "logs") else { return false }
                return call[i...].contains("-f")
            })
        }
    }

    private func insertApp() async throws -> VM {
        let yaml = """
        services:
          qbittorrent:
            image: lscr.io/linuxserver/qbittorrent:latest
            volumes:
              - config:/config
        volumes:
          config:
        """
        let now = "2026-01-01T00:00:00Z"
        var vm = VM(
            id: "app-qb",
            name: "qBittorrent",
            vmType: WorkloadSpec.applicationGuestType,
            state: "stopped",
            cpuCount: 1,
            memoryMb: 256,
            bootDiskId: nil,
            kind: WorkloadSpec.kindApplication,
            composeYaml: yaml,
            composeProject: ComposeRuntime.composeProjectName(id: "app-qb"),
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
            createdAt: now,
            updatedAt: now,
        )
        vm.syncSpecProjection(bumpGeneration: false)
        let row = vm
        try await dbPool.write { db in try row.insert(db) }
        return vm
    }
}

private final class RecordingComposeRunner: ComposeCommandRunning, @unchecked Sendable {
    var calls: [[String]] = []
    var logText = ""

    func run(
        arguments: [String],
        projectDirectory _: URL,
        timeout _: TimeInterval,
    ) throws -> CommandResult {
        calls.append(arguments)
        if arguments.contains("logs") {
            return CommandResult(exitCode: 0, stdout: Data(logText.utf8), stderr: Data())
        }
        if arguments.contains("-q") {
            return CommandResult(exitCode: 0, stdout: Data("cid1\n".utf8), stderr: Data())
        }
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

private final class RecordingDockerRunner: DockerCommandRunning, @unchecked Sendable {
    var inspectDigest = "sha256:aaa111bbb222"
    var manifestDigest = "sha256:bbb222ccc333"

    func run(arguments: [String], timeout _: TimeInterval) throws -> CommandResult {
        if arguments.first == "inspect" {
            let json = """
            [{"Config":{"Image":"lscr.io/linuxserver/qbittorrent:latest"},\
            "RepoDigests":["lscr.io/linuxserver/qbittorrent@\(inspectDigest)"]}]
            """
            return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
        if arguments.contains("manifest") {
            let json = "{\"Descriptor\":{\"digest\":\"\(manifestDigest)\"}}"
            return CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
        return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}
