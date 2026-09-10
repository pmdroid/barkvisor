import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
final class ApplicationLifecycleServiceTests {
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
