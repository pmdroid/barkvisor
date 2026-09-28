import Foundation
import Testing
@testable import BarkVisorCore

#if !os(Windows)
    struct LocalManagementSocketSchedulingTests {
        @Test func `an idle management listener releases its task executor`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("bv-idle-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("s").path
            let session = LocalManagementSession(
                policy: LocalManagementPolicy(
                    allowedPeerUIDs: [WorkloadPrivilegeDrop.currentEUID()],
                    memberships: [],
                    resources: ResourcePolicy(allowedRoots: [], allowedMounts: [], allowedDevices: []),
                ),
            )
            let server = LocalManagementSocketServer(
                path: path,
                session: session,
                directoryMode: 0o700,
                socketMode: 0o600,
            )
            defer { server.stop() }
            let executor = SocketTestExecutor()
            let serving = Task(executorPreference: executor) { try await server.run() }
            for _ in 0 ..< 100 {
                if FileManager.default.fileExists(atPath: path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: path))
            let heartbeat = Task(executorPreference: executor) { ContinuousClock.now }
            let stoppedAt = await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    let now = ContinuousClock.now
                    server.stop()
                    continuation.resume(returning: now)
                }
            }
            let heartbeatAt = await heartbeat.value
            try await serving.value
            #expect(heartbeatAt < stoppedAt)
        }
    }

    private final class SocketTestExecutor: TaskExecutor {
        private let queue = DispatchQueue(label: "barkvisor.socket-test-executor")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }
#endif
