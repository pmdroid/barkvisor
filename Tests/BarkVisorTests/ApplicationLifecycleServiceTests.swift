import Foundation
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
final class ApplicationLifecycleServiceTests {
    @Test func `down removes the project when compose fails`() throws {
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

        try ApplicationLifecycleService.down(vm: applicationVM(id: id), dataDir: dataDir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
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
