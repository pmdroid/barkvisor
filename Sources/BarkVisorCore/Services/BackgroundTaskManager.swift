import Foundation

public actor BackgroundTaskManager {
    public struct TaskEntry {
        public let id: String
        public let kind: TaskKind
        public let task: Task<Void, Never>
        public let createdAt: Date

        public init(id: String, kind: TaskKind, task: Task<Void, Never>, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.task = task
            self.createdAt = createdAt
        }
    }

    public enum TaskKind: String, Codable {
        case vmProvision
        case vmDelete
        case diagnosticBundle
        case repoSync
        case systemUpdate
    }

    public enum TaskStatus: String, Codable, Sendable {
        case queued
        case running
        case completed
        case failed
        case cancelled
    }

    public struct TaskEvent: Codable, Sendable {
        public let taskID: String
        public let kind: String
        public let status: TaskStatus
        public let progress: Double?
        public let error: String?
        public let resultPayload: String?

        public init(
            taskID: String, kind: String, status: TaskStatus, progress: Double?, error: String?,
            resultPayload: String?,
        ) {
            self.taskID = taskID
            self.kind = kind
            self.status = status
            self.progress = progress
            self.error = error
            self.resultPayload = resultPayload
        }
    }

    public init() {}

    private var periodicTasks: [String: Task<Void, Never>] = [:]
    private var tasks: [String: TaskEntry] = [:]
    private var latestEvents: OrderedTaskEventCache = .init()
    /// Track task IDs that were already cancelled/completed to prevent double-processing
    private var completedTaskIDs: Set<String> = []
    private var continuations: [String: [UUID: AsyncStream<TaskEvent>.Continuation]] = [:]
    private var waitQueues: [TaskKind: [(String, @Sendable () async throws -> String?)]] = [:]

    private let maxConcurrent: [TaskKind: Int] = [
        .vmProvision: 1,
        .vmDelete: 4,
        .diagnosticBundle: 1,
        .repoSync: 1,
        .systemUpdate: 1,
    ]

    private let maxDuration: [TaskKind: TimeInterval] = [
        .vmProvision: 600,
        .vmDelete: 120,
        .diagnosticBundle: 120,
        .repoSync: 120,
        .systemUpdate: 600,
    ]

    // MARK: - Public API

    @discardableResult
    public func submit(
        _ id: String, kind: TaskKind, work: @Sendable @escaping () async throws -> String?,
    ) -> String {
        // Duplicate check — return existing task ID if already running/queued
        if let existing = latestEvents[id], existing.status == .running || existing.status == .queued {
            return id
        }

        // Allow reuse of a previously completed task ID
        completedTaskIDs.remove(id)

        let runningCount = tasks.values.count(where: { $0.kind == kind })
        let limit = maxConcurrent[kind] ?? 4

        if runningCount >= limit {
            // Queue the work
            waitQueues[kind, default: []].append((id, work))
            let event = TaskEvent(
                taskID: id, kind: kind.rawValue, status: .queued, progress: nil, error: nil,
                resultPayload: nil,
            )
            latestEvents[id] = event
            emit(id: id, event: event)
            return id
        }

        startTask(id: id, kind: kind, work: work)
        return id
    }

    public func cancel(_ id: String) {
        if let entry = tasks[id] {
            entry.task.cancel()
            tasks.removeValue(forKey: id)
            completedTaskIDs.insert(id)
            let event = TaskEvent(
                taskID: id, kind: entry.kind.rawValue, status: .cancelled, progress: nil, error: nil,
                resultPayload: nil,
            )
            latestEvents[id] = event
            emit(id: id, event: event)
            finish(id: id)
            return
        }

        // Check wait queues
        for (kind, var queue) in waitQueues {
            if let idx = queue.firstIndex(where: { $0.0 == id }) {
                queue.remove(at: idx)
                waitQueues[kind] = queue
                completedTaskIDs.insert(id)
                let event = TaskEvent(
                    taskID: id, kind: kind.rawValue, status: .cancelled, progress: nil, error: nil,
                    resultPayload: nil,
                )
                latestEvents[id] = event
                emit(id: id, event: event)
                finish(id: id)
                return
            }
        }
    }

    public func status(_ id: String) -> TaskEvent? {
        latestEvents[id]
    }

    public func eventStream(_ id: String) -> AsyncStream<TaskEvent> {
        let uuid = UUID()
        return AsyncStream { continuation in
            // Send current state immediately if available
            if let current = latestEvents[id] {
                continuation.yield(current)
            }
            continuations[id, default: [:]][uuid] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id: id, uuid: uuid) }
            }
        }
    }

    public func cancelAll() {
        for (_, task) in periodicTasks {
            task.cancel()
        }
        periodicTasks.removeAll()

        for (_, entry) in tasks {
            entry.task.cancel()
        }
        tasks.removeAll()
        waitQueues.removeAll()
        for (id, conts) in continuations {
            for cont in conts.values {
                cont.finish()
            }
            continuations.removeValue(forKey: id)
        }
    }

    // MARK: - Periodic Tasks

    /// Schedule a recurring background task that runs on a fixed interval.
    /// The task is tracked and cancelled when `cancelAll()` is called.
    public func schedulePeriodicTask(
        id: String,
        interval: UInt64,
        work: @Sendable @escaping () async -> Void,
    ) {
        periodicTasks[id]?.cancel()
        periodicTasks[id] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await work()
            }
        }
    }

    /// Cancel a specific periodic task by ID.
    public func cancelPeriodicTask(id: String) {
        periodicTasks[id]?.cancel()
        periodicTasks.removeValue(forKey: id)
    }

    /// Emit a progress update for a running task from within the work closure
    public func reportProgress(_ id: String, progress: Double) {
        guard let event = latestEvents[id], event.status == .running else { return }
        let updated = TaskEvent(
            taskID: id, kind: event.kind, status: .running, progress: progress, error: nil,
            resultPayload: nil,
        )
        latestEvents[id] = updated
        emit(id: id, event: updated)
    }

    // MARK: - Private

    private func startTask(
        id: String, kind: TaskKind, work: @Sendable @escaping () async throws -> String?,
    ) {
        let event = TaskEvent(
            taskID: id, kind: kind.rawValue, status: .running, progress: 0, error: nil, resultPayload: nil,
        )
        latestEvents[id] = event
        emit(id: id, event: event)

        let timeout = maxDuration[kind] ?? 300

        let task = Task<Void, Never> {
            let result: TaskEvent
            do {
                let payload = try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask { try await work() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw CancellationError()
                    }
                    let value = try await group.next()
                    group.cancelAll()
                    return value.flatMap(\.self)
                }
                result = TaskEvent(
                    taskID: id, kind: kind.rawValue, status: .completed, progress: 1.0, error: nil,
                    resultPayload: payload,
                )
            } catch is CancellationError {
                result = TaskEvent(
                    taskID: id,
                    kind: kind.rawValue,
                    status: .cancelled,
                    progress: nil,
                    error: "Task cancelled or timed out",
                    resultPayload: nil,
                )
            } catch {
                result = TaskEvent(
                    taskID: id,
                    kind: kind.rawValue,
                    status: .failed,
                    progress: nil,
                    error: error.localizedDescription,
                    resultPayload: nil,
                )
            }

            self.completeTask(id: id, kind: kind, event: result)
        }

        tasks[id] = TaskEntry(id: id, kind: kind, task: task, createdAt: Date())
    }

    private func completeTask(id: String, kind: TaskKind, event: TaskEvent) {
        // Guard against double-completion (e.g., cancel() already processed this task)
        if completedTaskIDs.contains(id) {
            return
        }
        completedTaskIDs.insert(id)

        tasks.removeValue(forKey: id)
        latestEvents[id] = event
        emit(id: id, event: event)
        finish(id: id)

        // Drain wait queue for this kind
        if var queue = waitQueues[kind], !queue.isEmpty {
            let (nextID, nextWork) = queue.removeFirst()
            waitQueues[kind] = queue
            startTask(id: nextID, kind: kind, work: nextWork)
        }
    }

    private func emit(id: String, event: TaskEvent) {
        guard let conts = continuations[id] else { return }
        for cont in conts.values {
            cont.yield(event)
        }
    }

    private func finish(id: String) {
        if let conts = continuations.removeValue(forKey: id) {
            for cont in conts.values {
                cont.finish()
            }
        }
    }

    private func removeContinuation(id: String, uuid: UUID) {
        continuations[id]?.removeValue(forKey: uuid)
        if continuations[id]?.isEmpty == true {
            continuations.removeValue(forKey: id)
        }
    }
}

/// Bounded cache for task events — evicts oldest entries when capacity is exceeded.
private struct OrderedTaskEventCache {
    private var dict: [String: BackgroundTaskManager.TaskEvent] = [:]
    private var insertionOrder: [String] = []
    private let maxSize = 1_000

    subscript(key: String) -> BackgroundTaskManager.TaskEvent? {
        get { dict[key] }
        set {
            if let value = newValue {
                if dict[key] == nil {
                    insertionOrder.append(key)
                }
                dict[key] = value
                evictIfNeeded()
            } else {
                dict.removeValue(forKey: key)
                insertionOrder.removeAll { $0 == key }
            }
        }
    }

    private mutating func evictIfNeeded() {
        while dict.count > maxSize, !insertionOrder.isEmpty {
            let oldest = insertionOrder.removeFirst()
            dict.removeValue(forKey: oldest)
        }
    }
}
