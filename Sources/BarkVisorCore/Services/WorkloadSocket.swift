import Foundation
import GRDB

public struct WorkloadSocketCommand: Equatable, Sendable {
    public var operationID: String
    public var workloadID: String
    public var kind: String

    public init(operationID: String, workloadID: String, kind: String) {
        self.operationID = operationID
        self.workloadID = workloadID
        self.kind = kind
    }
}

public struct WorkloadSocketSnapshot: Equatable, Sendable {
    public var workloadID: String
    public var state: String
    public var runtime: String

    public init(workloadID: String, state: String, runtime: String) {
        self.workloadID = workloadID
        self.state = state
        self.runtime = runtime
    }
}

public struct DurableWorkloadOperation: Codable, Equatable, Sendable {
    public var operationID: String
    public var workloadID: String
    public var subject: String
    public var kind: String
    public var phase: String
    public var state: String
    public var runtime: String
    public var events: [String]
    public var sequence: Int

    public init(
        operationID: String,
        workloadID: String,
        subject: String,
        kind: String,
        phase: String,
        state: String,
        runtime: String,
        events: [String],
        sequence: Int,
    ) {
        self.operationID = operationID
        self.workloadID = workloadID
        self.subject = subject
        self.kind = kind
        self.phase = phase
        self.state = state
        self.runtime = runtime
        self.events = events
        self.sequence = sequence
    }
}

public protocol DurableOperationStoring: Sendable {
    func find(operationID: String) async -> DurableWorkloadOperation?
    func latest(workloadID: String) async -> DurableWorkloadOperation?
    func save(_ record: DurableWorkloadOperation) async
}

public protocol WorkloadSocketDriving: Sendable {
    func perform(_ command: WorkloadSocketCommand) async throws -> WorkloadSocketSnapshot
}

public actor DurableOperationFile: DurableOperationStoring {
    private let url: URL
    private var records: [String: DurableWorkloadOperation]

    public init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DurableWorkloadOperation].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.operationID, $0) })
        } else {
            records = [:]
        }
    }

    public func find(operationID: String) -> DurableWorkloadOperation? {
        records[operationID]
    }

    public func latest(workloadID: String) -> DurableWorkloadOperation? {
        records.values
            .filter { $0.workloadID == workloadID && $0.phase == "completed" }
            .max { $0.sequence < $1.sequence }
    }

    public func save(_ record: DurableWorkloadOperation) {
        records[record.operationID] = record
        let payload = (try? JSONEncoder().encode(Array(records.values))) ?? Data()
        try? payload.write(to: url, options: .atomic)
    }
}

public final class RecordingWorkloadSocketDriver: WorkloadSocketDriving, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var calls: [WorkloadSocketCommand] = []
    public private(set) var states: [String: String] = [:]

    public init() {}

    public func perform(_ command: WorkloadSocketCommand) async throws -> WorkloadSocketSnapshot {
        try record(command)
    }

    private func record(_ command: WorkloadSocketCommand) throws -> WorkloadSocketSnapshot {
        lock.lock()
        defer { lock.unlock() }
        calls.append(command)
        let state: String
        switch command.kind {
        case "start", "update":
            state = "running"
        case "stop":
            state = "stopped"
        case "delete":
            state = "deleted"
        default:
            throw LocalManagementError.malformed
        }
        let runtime = command.workloadID.hasPrefix("app-") ? "docker" : "qemu"
        states[command.workloadID] = "\(state):\(runtime)"
        return WorkloadSocketSnapshot(
            workloadID: command.workloadID,
            state: state,
            runtime: runtime,
        )
    }
}

public struct LiveWorkloadSocketDriver: WorkloadSocketDriving {
    private let db: DatabasePool
    private let vmManager: VMManager
    private let tasks: BackgroundTaskManager

    public init(db: DatabasePool, vmManager: VMManager, tasks: BackgroundTaskManager) {
        self.db = db
        self.vmManager = vmManager
        self.tasks = tasks
    }

    public func perform(_ command: WorkloadSocketCommand) async throws -> WorkloadSocketSnapshot {
        guard let vm = try await db.read({ database in
            try VM.fetchOne(database, key: command.workloadID)
        }) else {
            throw BarkVisorError.notFound("Workload \(command.workloadID) not found")
        }
        let runtime = vm.isApplication ? "docker" : "qemu"
        switch command.kind {
        case "start":
            if vm.isApplication {
                var live = vm
                try await ApplicationLifecycleService.start(vm: &live, db: db)
                return WorkloadSocketSnapshot(workloadID: vm.id, state: live.state, runtime: runtime)
            }
            try await vmManager.start(vmID: vm.id)
            return WorkloadSocketSnapshot(workloadID: vm.id, state: "running", runtime: runtime)
        case "stop":
            if vm.isApplication {
                var live = vm
                try await ApplicationLifecycleService.stop(vm: &live, db: db)
                return WorkloadSocketSnapshot(workloadID: vm.id, state: live.state, runtime: runtime)
            }
            try await vmManager.stop(vmID: vm.id, force: false, method: "acpi")
            return WorkloadSocketSnapshot(workloadID: vm.id, state: "stopped", runtime: runtime)
        case "update":
            if vm.isApplication {
                var live = vm
                try await ApplicationLifecycleService.updateImages(vm: &live, db: db)
                return WorkloadSocketSnapshot(workloadID: vm.id, state: live.state, runtime: runtime)
            }
            try await vmManager.restart(vmID: vm.id)
            return WorkloadSocketSnapshot(workloadID: vm.id, state: "running", runtime: runtime)
        case "delete":
            let (taskID, _) = try await VMLifecycleService.deleteVM(
                id: vm.id,
                keepDisk: false,
                vmManager: vmManager,
                backgroundTasks: tasks,
                db: db,
            )
            try await waitForDelete(taskID)
            return WorkloadSocketSnapshot(workloadID: vm.id, state: "deleted", runtime: runtime)
        default:
            throw LocalManagementError.malformed
        }
    }

    private func waitForDelete(_ taskID: String) async throws {
        for _ in 0 ..< 400 {
            if let event = await tasks.status(taskID) {
                switch event.status {
                case .completed:
                    return
                case .failed, .cancelled:
                    throw BarkVisorError.conflict(event.error ?? "Workload delete did not finish")
                case .queued, .running:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BarkVisorError.conflict("Workload delete did not finish")
    }
}

enum WorkloadSocketOperations {
    static let names: Set<String> = [
        "workload.start",
        "workload.stop",
        "workload.update",
        "workload.delete",
        "workload.status",
        "workload.events",
    ]

    static func kind(for name: String) -> String? {
        switch name {
        case "workload.start": "start"
        case "workload.stop": "stop"
        case "workload.update": "update"
        case "workload.delete": "delete"
        default: nil
        }
    }

    static func response(
        request: LocalManagementRequest,
        record: DurableWorkloadOperation,
        events: [String]?,
    ) -> LocalManagementResponse {
        LocalManagementResponse(
            requestId: request.requestId,
            operationId: record.operationID,
            accepted: record.phase == "completed" || record.phase == "accepted",
            phase: record.phase,
            effectCount: record.phase == "completed" ? 1 : 0,
            subject: record.subject,
            marker: record.runtime,
            workloadID: record.workloadID,
            workloadState: record.state,
            events: events,
        )
    }
}
