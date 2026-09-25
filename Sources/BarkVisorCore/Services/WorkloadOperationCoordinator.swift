import Foundation
import GRDB

public struct LeaseObservation: Sendable, Equatable {
    public var generation: Int
    public var state: String
    public var exists: Bool

    public init(generation: Int, state: String, exists: Bool) {
        self.generation = generation
        self.state = state
        self.exists = exists
    }
}

public struct WorkloadOperationIdentity: Hashable, Sendable {
    public var workloadID: String
    public var operationID: String

    public init(workloadID: String, operationID: String) {
        self.workloadID = workloadID
        self.operationID = operationID
    }
}

public enum LeaseKind: String, Sendable {
    case start
    case stop
    case restart
    case update
    case delete
    case sync
    case reconcile
    case recover
}

public struct WorkloadOperationLease: Sendable {
    public let identity: WorkloadOperationIdentity
    public let kind: LeaseKind
    public let generation: Int
    public let state: String
    public let mutationEpoch: UInt64
    let operations: WorkloadOperationCoordinator

    public func isCancelRequested() async -> Bool {
        await operations.isCancelRequested(identity)
    }

    public func atGeneration(_ generation: Int) -> WorkloadOperationLease {
        WorkloadOperationLease(
            identity: identity,
            kind: kind,
            generation: generation,
            state: state,
            mutationEpoch: mutationEpoch,
            operations: operations,
        )
    }
}

public struct DeviceWorkloadControl: Sendable {
    public let operations: WorkloadOperationCoordinator
    public let vmManager: VMManager

    public init(dbPool: DatabasePool) {
        let operations = WorkloadOperationCoordinator()
        self.operations = operations
        self.vmManager = VMManager(dbPool: dbPool, operations: operations)
    }
}

public actor WorkloadOperationCoordinator {
    public static let operationHeaderName = "X-BarkVisor-Operation-Id"

    private struct Lane {
        var busy = false
        var owner: WorkloadOperationIdentity?
        var cancelRequested = false
        var mutationEpoch: UInt64 = 0
        var waiters: [LaneWaiter] = []
    }

    private struct LaneWaiter {
        var operationID: String
        var continuation: CheckedContinuation<Void, Error>
    }

    private final class Outcome: @unchecked Sendable {
        let kind: LeaseKind
        private let lock = NSLock()
        private var result: Result<AnySendable, Error>?
        private var waiters: [CheckedContinuation<Result<AnySendable, Error>, Never>] = []
        private var finished = false

        init(kind: LeaseKind) {
            self.kind = kind
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func finish(_ result: Result<AnySendable, Error>) {
            lock.lock()
            self.result = result
            finished = true
            let pending = waiters
            waiters = []
            lock.unlock()
            for waiter in pending {
                waiter.resume(returning: result)
            }
        }

        func wait() async -> Result<AnySendable, Error> {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    private struct AnySendable: @unchecked Sendable {
        let value: Any
    }

    private var lanes: [String: Lane] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var finishedOrder: [String: [String]] = [:]
    private let finishedOutcomeCap = 32

    public init() {}

    public static func makeOperationID(supplied: String?, action: String, workloadID: String) -> String {
        let trimmed = supplied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return "\(action):\(workloadID):\(UUID().uuidString)"
    }

    public static func operationHeader(from supplied: String?) -> (String, String)? {
        let trimmed = supplied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return (operationHeaderName, trimmed)
    }

    public static func observation(id: String, db: DatabasePool) async throws -> LeaseObservation {
        if let vm = try await db.read({ try VM.fetchOne($0, key: id) }) {
            return LeaseObservation(generation: vm.specGeneration, state: vm.state, exists: true)
        }
        return LeaseObservation(generation: 0, state: "absent", exists: false)
    }

    public nonisolated func perform<T: Sendable>(
        workloadID: String,
        operationID: String,
        kind: LeaseKind,
        load: @escaping @Sendable () async throws -> LeaseObservation,
        body: @escaping @Sendable (WorkloadOperationLease) async throws -> T,
    ) async throws -> T {
        let effects = InheritedEffects.current()
        return try await performIsolated(
            workloadID: workloadID,
            operationID: operationID,
            kind: kind,
            load: load,
            body: body,
            effects: effects,
        )
    }

    private func performIsolated<T: Sendable>(
        workloadID: String,
        operationID: String,
        kind: LeaseKind,
        load: @escaping @Sendable () async throws -> LeaseObservation,
        body: @escaping @Sendable (WorkloadOperationLease) async throws -> T,
        effects: InheritedEffects,
    ) async throws -> T {
        let key = "\(workloadID)\n\(operationID)"
        if let existing = outcomes[key] {
            if existing.kind != kind {
                throw BarkVisorError.conflict(
                    "Operation \(operationID) is already \(existing.kind.rawValue)",
                )
            }
            return try await Self.unwrap(existing.wait(), as: T.self)
        }
        let outcome = Outcome(kind: kind)
        outcomes[key] = outcome
        let task = Task.detached { () -> Result<AnySendable, Error> in
            do {
                let value = try await self.execute(
                    workloadID: workloadID,
                    operationID: operationID,
                    kind: kind,
                    load: load,
                    body: body,
                    effects: effects,
                )
                return .success(AnySendable(value: value))
            } catch {
                return .failure(error)
            }
        }
        let result = await task.value
        outcome.finish(result)
        trimFinishedOutcomes(workloadID: workloadID, key: key)
        return try Self.unwrap(result, as: T.self)
    }

    private func trimFinishedOutcomes(workloadID: String, key: String) {
        var order = finishedOrder[workloadID] ?? []
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > finishedOutcomeCap {
            let dropped = order.removeFirst()
            if outcomes[dropped]?.isFinished == true {
                outcomes.removeValue(forKey: dropped)
            }
        }
        finishedOrder[workloadID] = order
    }

    public func requestCancel(workloadID: String, operationID: String) {
        guard var lane = lanes[workloadID] else { return }
        if lane.owner?.operationID == operationID {
            lane.cancelRequested = true
            lanes[workloadID] = lane
            return
        }
        guard let index = lane.waiters.firstIndex(where: { $0.operationID == operationID }) else {
            return
        }
        let waiter = lane.waiters.remove(at: index)
        lanes[workloadID] = lane
        waiter.continuation.resume(throwing: CancellationError())
    }

    public func allowsWrite(lease: WorkloadOperationLease, current: LeaseObservation) -> Bool {
        guard lanes[lease.identity.workloadID]?.owner == lease.identity else { return false }
        guard lanes[lease.identity.workloadID]?.mutationEpoch == lease.mutationEpoch else { return false }
        switch lease.kind {
        case .reconcile:
            guard current.exists, current.generation == lease.generation else { return false }
            switch current.state {
            case "starting", "stopping", "provisioning", "deleting":
                return false
            default:
                return true
            }
        case .delete:
            if !current.exists { return true }
            return current.generation == lease.generation
        default:
            guard current.exists, current.generation == lease.generation else { return false }
            return current.state != "deleting"
        }
    }

    public func isCancelRequested(_ identity: WorkloadOperationIdentity) -> Bool {
        guard let lane = lanes[identity.workloadID], lane.owner == identity else { return false }
        return lane.cancelRequested
    }

    private func execute<T: Sendable>(
        workloadID: String,
        operationID: String,
        kind: LeaseKind,
        load: @escaping @Sendable () async throws -> LeaseObservation,
        body: @escaping @Sendable (WorkloadOperationLease) async throws -> T,
        effects: InheritedEffects,
    ) async throws -> T {
        try await acquire(workloadID: workloadID, operationID: operationID)
        var holding = true
        do {
            var lane = lanes[workloadID] ?? Lane()
            let identity = WorkloadOperationIdentity(workloadID: workloadID, operationID: operationID)
            lane.owner = identity
            lane.cancelRequested = false
            if kind != .reconcile {
                lane.mutationEpoch += 1
            }
            let epoch = lane.mutationEpoch
            lanes[workloadID] = lane
            let observation = try await load()
            if kind != .delete, !observation.exists {
                release(workloadID: workloadID)
                holding = false
                throw BarkVisorError.notFound("Workload \(workloadID) not found")
            }
            let lease = WorkloadOperationLease(
                identity: identity,
                kind: kind,
                generation: observation.generation,
                state: observation.state,
                mutationEpoch: epoch,
                operations: self,
            )
            let value = try await Task.detached {
                try await effects.apply { try await body(lease) }
            }.value
            release(workloadID: workloadID)
            holding = false
            return value
        } catch {
            if holding {
                release(workloadID: workloadID)
            }
            throw error
        }
    }

    private func acquire(workloadID: String, operationID: String) async throws {
        var lane = lanes[workloadID] ?? Lane()
        if !lane.busy {
            lane.busy = true
            lanes[workloadID] = lane
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var waiting = lanes[workloadID] ?? Lane()
            waiting.waiters.append(
                LaneWaiter(operationID: operationID, continuation: continuation),
            )
            lanes[workloadID] = waiting
        }
    }

    private func release(workloadID: String) {
        guard var lane = lanes[workloadID] else { return }
        lane.owner = nil
        lane.cancelRequested = false
        if lane.waiters.isEmpty {
            lane.busy = false
            lanes[workloadID] = lane
            return
        }
        let next = lane.waiters.removeFirst()
        lane.busy = true
        lanes[workloadID] = lane
        next.continuation.resume()
    }

    private static func unwrap<T>(_ result: Result<AnySendable, Error>, as type: T.Type) throws -> T {
        switch result {
        case let .success(box):
            guard let value = box.value as? T else {
                throw BarkVisorError.conflict("Operation finished with a different result")
            }
            return value
        case let .failure(error):
            throw error
        }
    }
}

private struct InheritedEffects {
    var composeRunner: (any ComposeCommandRunning)?
    var dockerRunner: (any DockerCommandRunning)?
    var dockerSnapshot: DockerEngineSnapshot?
    var dockerInspect: (@Sendable ([String]) throws -> Data)?
    var effectHook: (@Sendable (String) throws -> Void)?
    var healthTimeout: TimeInterval?
    var adoptionAlive: (@Sendable (String, URL) -> Bool)?

    static func current() -> Self {
        Self(
            composeRunner: ComposeRuntime.runnerOverride,
            dockerRunner: DockerCLI.runnerOverride,
            dockerSnapshot: DockerEngine.snapshotOverride,
            dockerInspect: DockerInspect.jsonOverride,
            effectHook: WorkloadEffectGate.hook,
            healthTimeout: WorkloadEffectGate.healthTimeout,
            adoptionAlive: VMAdoptionProbe.alive,
        )
    }

    func apply<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await ComposeRuntime.$runnerOverride.withValue(composeRunner) {
            try await DockerCLI.$runnerOverride.withValue(dockerRunner) {
                try await DockerEngine.$snapshotOverride.withValue(dockerSnapshot) {
                    try await DockerInspect.$jsonOverride.withValue(dockerInspect) {
                        try await WorkloadEffectGate.$hook.withValue(effectHook) {
                            try await WorkloadEffectGate.$healthTimeout.withValue(healthTimeout) {
                                try await VMAdoptionProbe.$alive.withValue(adoptionAlive) {
                                    try await body()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
