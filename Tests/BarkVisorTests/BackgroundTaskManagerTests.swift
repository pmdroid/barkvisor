import XCTest
@testable import BarkVisorCore

final class BackgroundTaskManagerTests: XCTestCase {
    // MARK: - Submit and complete

    func testSubmitAndComplete() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.submit("task-1", kind: .diagnosticBundle) {
            return "done"
        }
        XCTAssertEqual(id, "task-1")

        // Wait for the task to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        let event = await manager.status("task-1")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.status, .completed)
        XCTAssertEqual(event?.resultPayload, "done")
    }

    func testSubmitDuplicate() async {
        let manager = BackgroundTaskManager()

        // Submit a long-running task
        await manager.submit("task-1", kind: .diagnosticBundle) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return nil
        }

        // Wait for it to start
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Submit again with same ID — should return existing
        let id2 = await manager.submit("task-1", kind: .diagnosticBundle) {
            return "should not run"
        }
        XCTAssertEqual(id2, "task-1")

        await manager.cancelAll()
    }

    // MARK: - Cancel

    func testCancel() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .repoSync) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        }

        // Wait for it to start
        try await Task.sleep(nanoseconds: 100_000_000)

        await manager.cancel("task-1")

        let event = await manager.status("task-1")
        XCTAssertEqual(event?.status, .cancelled)
    }

    // MARK: - Failed task

    func testFailedTask() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .diagnosticBundle) {
            throw BarkVisorError.internalError("test failure")
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let event = await manager.status("task-1")
        XCTAssertEqual(event?.status, .failed)
        XCTAssertNotNil(event?.error)
    }

    // MARK: - Progress

    func testReportProgress() async throws {
        let manager = BackgroundTaskManager()
        await manager.submit("task-1", kind: .vmProvision) {
            await manager.reportProgress("task-1", progress: 0.5)
            return nil
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        // Task should be completed by now, but progress was reported during execution
        let event = await manager.status("task-1")
        XCTAssertNotNil(event)
    }

    // MARK: - Concurrency limits (queue)

    func testConcurrencyLimitQueues() async throws {
        let manager = BackgroundTaskManager()

        // vmProvision has limit of 1
        await manager.submit("task-1", kind: .vmProvision) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return "first"
        }

        // Wait for first task to start
        try await Task.sleep(nanoseconds: 100_000_000)

        // This should be queued
        await manager.submit("task-2", kind: .vmProvision) {
            return "second"
        }

        let event2 = await manager.status("task-2")
        XCTAssertEqual(event2?.status, .queued, "Second task should be queued when limit is reached")

        await manager.cancelAll()
    }

    // MARK: - CancelAll

    func testCancelAll() async throws {
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

        // After cancelAll, no running tasks should remain
        // (The status may or may not be updated depending on timing, but cancelAll should not crash)
    }

    // MARK: - TaskStatus Codable

    func testTaskStatusCodable() throws {
        let statuses: [BackgroundTaskManager.TaskStatus] = [
            .queued, .running, .completed, .failed, .cancelled,
        ]
        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(BackgroundTaskManager.TaskStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - TaskKind Codable

    func testTaskKindCodable() throws {
        let kinds: [BackgroundTaskManager.TaskKind] = [
            .vmProvision, .vmDelete, .diagnosticBundle, .repoSync,
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(BackgroundTaskManager.TaskKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - TaskEvent Codable

    func testTaskEventCodable() throws {
        let event = BackgroundTaskManager.TaskEvent(
            taskID: "t1", kind: "vmProvision", status: .completed,
            progress: 1.0, error: nil, resultPayload: "{\"vmId\":\"vm-1\"}",
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BackgroundTaskManager.TaskEvent.self, from: data)
        XCTAssertEqual(decoded.taskID, "t1")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.progress, 1.0)
        XCTAssertEqual(decoded.resultPayload, "{\"vmId\":\"vm-1\"}")
    }
}
