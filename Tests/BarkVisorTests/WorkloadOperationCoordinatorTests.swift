import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite(.serialized)
struct WorkloadOperationCoordinatorTests {
    @Test func `suspended operation blocks a second mutation of the same Workload`() async throws {
        let coordinator = WorkloadOperationCoordinator()
        let gate = Gate()
        let runs = Counter()
        let first = Task {
            try await coordinator.perform(
                workloadID: "app-a",
                operationID: "start-1",
                kind: .start,
                load: { Self.running },
            ) { _ in
                await runs.increment()
                await gate.enter()
                return "first"
            }
        }
        try await waitUntil { await gate.enteredCount() == 1 }
        let second = Task {
            try await coordinator.perform(
                workloadID: "app-a",
                operationID: "stop-2",
                kind: .stop,
                load: { Self.running },
            ) { _ in
                await runs.increment()
                return "second"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await runs.value() == 1)
        await gate.open()
        #expect(try await first.value == "first")
        #expect(try await second.value == "second")
        #expect(await runs.value() == 2)
    }

    @Test func `different Workloads run while another is suspended`() async throws {
        let coordinator = WorkloadOperationCoordinator()
        let gate = Gate()
        let entered = Counter()
        let pull = Task {
            try await coordinator.perform(
                workloadID: "app-pull",
                operationID: "update-pull",
                kind: .update,
                load: { Self.running },
            ) { _ in
                await entered.increment()
                await gate.enter()
            }
        }
        let other = Task {
            try await coordinator.perform(
                workloadID: "vm-other",
                operationID: "start-other",
                kind: .start,
                load: { Self.stopped },
            ) { _ in
                await entered.increment()
            }
        }
        try await waitUntil { await entered.value() == 2 }
        #expect(pull.isCancelled == false)
        await gate.open()
        try await pull.value
        try await other.value
    }

    @Test func `retry of an accepted operation does not run the mutation twice`() async throws {
        let coordinator = WorkloadOperationCoordinator()
        let gate = Gate()
        let runs = Counter()
        let first = Task {
            try await coordinator.perform(
                workloadID: "vm-1",
                operationID: "op-retry",
                kind: .start,
                load: { Self.stopped },
            ) { _ in
                await runs.increment()
                await gate.enter()
                return "once"
            }
        }
        try await waitUntil { await gate.enteredCount() == 1 }
        let retry = Task {
            try await coordinator.perform(
                workloadID: "vm-1",
                operationID: "op-retry",
                kind: .start,
                load: { Self.stopped },
            ) { _ in
                await runs.increment()
                return "twice"
            }
        }
        await gate.open()
        #expect(try await first.value == "once")
        #expect(try await retry.value == "once")
        #expect(await runs.value() == 1)
    }

    @Test func `cancellation releases the lane only after the body settles`() async throws {
        let coordinator = WorkloadOperationCoordinator()
        let gate = Gate()
        let settled = Counter()
        let secondRuns = Counter()
        let first = Task {
            try await coordinator.perform(
                workloadID: "app-cancel",
                operationID: "update-cancel",
                kind: .update,
                load: { Self.running },
            ) { lease in
                await gate.enter()
                if await lease.isCancelRequested() {
                    await settled.increment()
                }
                return "cancelled"
            }
        }
        try await waitUntil { await gate.enteredCount() == 1 }
        await coordinator.requestCancel(workloadID: "app-cancel", operationID: "update-cancel")
        let second = Task {
            try await coordinator.perform(
                workloadID: "app-cancel",
                operationID: "stop-after-cancel",
                kind: .stop,
                load: { Self.running },
            ) { _ in
                await secondRuns.increment()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await secondRuns.value() == 0)
        #expect(await settled.value() == 0)
        await gate.open()
        #expect(try await first.value == "cancelled")
        #expect(await settled.value() == 1)
        try await second.value
        #expect(await secondRuns.value() == 1)
    }

    @Test func `reconciliation cannot overwrite a newer generation or a finished operation`() async throws {
        let coordinator = WorkloadOperationCoordinator()
        let stale = try await coordinator.perform(
            workloadID: "app-obs",
            operationID: "reconcile-1",
            kind: .reconcile,
            load: { Self.running },
        ) { lease -> Bool in
            let newer = LeaseObservation(generation: lease.generation + 1, state: "running", exists: true)
            let same = LeaseObservation(generation: lease.generation, state: "running", exists: true)
            let starting = LeaseObservation(generation: lease.generation, state: "starting", exists: true)
            let deleted = LeaseObservation(generation: lease.generation, state: "running", exists: false)
            let newerAllowed = await coordinator.allowsWrite(lease: lease, current: newer)
            let sameAllowed = await coordinator.allowsWrite(lease: lease, current: same)
            let startingAllowed = await coordinator.allowsWrite(lease: lease, current: starting)
            let deletedAllowed = await coordinator.allowsWrite(lease: lease, current: deleted)
            #expect(!newerAllowed)
            #expect(sameAllowed)
            #expect(!startingAllowed)
            #expect(!deletedAllowed)
            return await coordinator.allowsWrite(lease: lease, current: same)
        }
        #expect(stale)
        let late = WorkloadOperationLease(
            identity: WorkloadOperationIdentity(workloadID: "app-obs", operationID: "reconcile-1"),
            kind: .reconcile,
            generation: 3,
            state: "running",
            mutationEpoch: 0,
            operations: coordinator,
        )
        let allowed = await coordinator.allowsWrite(lease: late, current: Self.running)
        #expect(!allowed)
    }

    @Test func `a missing Workload is not started`() async {
        let coordinator = WorkloadOperationCoordinator()
        let runs = Counter()
        await #expect(throws: BarkVisorError.self) {
            try await coordinator.perform(
                workloadID: "gone",
                operationID: "start-gone",
                kind: .start,
                load: { LeaseObservation(generation: 1, state: "absent", exists: false) },
            ) { _ in
                await runs.increment()
            }
        }
        #expect(await runs.value() == 0)
    }

    @Test func `one Device constructs a single operation owner`() throws {
        let pool = try DatabasePool(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-ops-\(UUID().uuidString).sqlite").path)
        let control = DeviceWorkloadControl(dbPool: pool)
        let again = DeviceWorkloadControl(dbPool: pool)
        #expect(control.vmManager.operations === control.operations)
        #expect(control.operations !== again.operations)
    }

    @Test func `runtime handle and sockets keep the complete Workload id`() async throws {
        let workloadID = "01234567-89ab-cdef-0123-456789abcdef"
        let sockets = VMSockets(vmID: workloadID)
        #expect(sockets.workloadID == workloadID)
        #expect(sockets.owned(by: workloadID))
        let foreign = VMSockets(vmID: "ffffffff-ffff-ffff-ffff-ffffffffffff")
        let pool = try DatabasePool(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-handle-\(UUID().uuidString).sqlite").path)
        let manager = VMManager(dbPool: pool)
        let mismatched = RunningVM(
            process: nil,
            pid: 9,
            serialSocketPath: sockets.serial.path,
            vncSocketPath: sockets.vnc.path,
            qmpSocketPath: foreign.qmp.path,
            qmpEventSocketPath: sockets.event.path,
            swtpmProcess: nil,
            reconnected: true,
            workloadID: workloadID,
        )
        await manager.registerReconnectedVM(vmID: workloadID, running: mismatched)
        #expect(await manager.isRunning(workloadID) == false)
        let matched = RunningVM(
            process: nil,
            pid: 9,
            serialSocketPath: sockets.serial.path,
            vncSocketPath: sockets.vnc.path,
            qmpSocketPath: sockets.qmp.path,
            qmpEventSocketPath: sockets.event.path,
            swtpmProcess: nil,
            reconnected: true,
            workloadID: workloadID,
        )
        await manager.registerReconnectedVM(vmID: workloadID, running: matched)
        #expect(await manager.isRunning(workloadID))
        #expect(await manager.runningVMs[workloadID]?.workloadID == workloadID)
    }

    @Test func `operation id prefers the supplied header value`() {
        #expect(
            WorkloadOperationCoordinator.makeOperationID(
                supplied: " retry-1 ", action: "start", workloadID: "vm",
            ) == "retry-1",
        )
        let generated = WorkloadOperationCoordinator.makeOperationID(
            supplied: " ", action: "start", workloadID: "vm",
        )
        #expect(generated.hasPrefix("start:vm:"))
        #expect(
            WorkloadOperationCoordinator.operationHeader(from: " hop-7 ")?.1 == "hop-7",
        )
        #expect(WorkloadOperationCoordinator.operationHeader(from: nil) == nil)
    }

    private static let running = LeaseObservation(generation: 3, state: "running", exists: true)
    private static let stopped = LeaseObservation(generation: 3, state: "stopped", exists: true)
}

private actor Counter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor Gate {
    private var entered = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered += 1
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func enteredCount() -> Int {
        entered
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool,
) async throws {
    for _ in 0 ..< 100 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("condition was not met")
}
