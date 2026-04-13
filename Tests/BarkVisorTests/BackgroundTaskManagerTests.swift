import Foundation
import Testing
@testable import BarkVisorCore

struct BackgroundTaskManagerTests {
    // MARK: - Submit and complete

    @Test func `submit and complete`() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.submit("task-1", kind: .diagnosticBundle) { "done" }
        #expect(id == "task-1")

        try await Task.sleep(nanoseconds: 200_000_000)

        let event = await manager.status("task-1")
        #expect(event != nil)
        #expect(event?.status == .completed)
        #expect(event?.resultPayload == "done")
    }

    @Test func `submit duplicate`() async {
        let manager = BackgroundTaskManager()

        await manager.submit("task-1", kind: .diagnosticBundle) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return nil
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        let id2 = await manager.submit("task-1", kind: .diagnosticBundle) { "should not run" }
        #expect(id2 == "task-1")

        await manager.cancelAll()
    }

    // MARK: - Cancel

    @Test func cancel() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .repoSync) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await manager.cancel("task-1")

        let event = await manager.status("task-1")
        #expect(event?.status == .cancelled)
    }

    // MARK: - Failed task

    @Test func `failed task`() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .diagnosticBundle) {
            throw BarkVisorError.internalError("test failure")
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let event = await manager.status("task-1")
        #expect(event?.status == .failed)
        #expect(event?.error != nil)
    }

    // MARK: - Progress

    @Test func `report progress`() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .vmProvision) {
            await manager.reportProgress("task-1", progress: 0.5)
            return nil
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let event = await manager.status("task-1")
        #expect(event != nil)
    }

    // MARK: - Concurrency limits (queue)

    @Test func `concurrency limit queues`() async throws {
        let manager = BackgroundTaskManager()

        await manager.submit("task-1", kind: .vmProvision) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return "first"
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await manager.submit("task-2", kind: .vmProvision) { "second" }

        let event2 = await manager.status("task-2")
        #expect(event2?.status == .queued, "Second task should be queued when limit is reached")

        await manager.cancelAll()
    }

    // MARK: - CancelAll

    @Test func `cancel all`() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .diagnosticBundle) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        }
        await manager.submit("task-2", kind: .repoSync) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await manager.cancelAll()
    }

    // MARK: - TaskStatus Codable

    @Test func `task status codable`() throws {
        let statuses: [BackgroundTaskManager.TaskStatus] = [.queued, .running, .completed, .failed, .cancelled]
        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(BackgroundTaskManager.TaskStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    // MARK: - TaskKind Codable

    @Test func `task kind codable`() throws {
        let kinds: [BackgroundTaskManager.TaskKind] = [.vmProvision, .vmDelete, .diagnosticBundle, .repoSync]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(BackgroundTaskManager.TaskKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    // MARK: - TaskEvent Codable

    @Test func `task event codable`() throws {
        let event = BackgroundTaskManager.TaskEvent(
            taskID: "t1", kind: "vmProvision", status: .completed,
            progress: 1.0, error: nil, resultPayload: "{\"vmId\":\"vm-1\"}",
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BackgroundTaskManager.TaskEvent.self, from: data)
        #expect(decoded.taskID == "t1")
        #expect(decoded.status == .completed)
        #expect(decoded.progress == 1.0)
        #expect(decoded.resultPayload == "{\"vmId\":\"vm-1\"}")
    }
}
