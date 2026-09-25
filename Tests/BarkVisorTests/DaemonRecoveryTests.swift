import Foundation
import Testing
@testable import BarkVisorCore

struct DaemonRecoveryTests {
    @Test func `restart adopts A running workload and does not repeat A completed delete`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-recover-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = directory.appendingPathComponent("disk.img")
        FileManager.default.createFile(atPath: volume.path, contents: Data("volume".utf8))
        let started = record(id: "op-start", workload: "vm-1", kind: "start", phase: "accepted", state: "accepted")
        let deleted = record(id: "op-del", workload: "vm-2", kind: "delete", phase: "completed", state: "deleted")
        let plan = DaemonRecovery.reconcile(
            records: [started, deleted],
            running: ["vm-1"],
            present: ["vm-1"],
        )
        #expect(plan.commands.isEmpty)
        #expect(plan.records.first { $0.operationID == "op-start" }?.phase == "completed")
        #expect(plan.records.first { $0.operationID == "op-start" }?.state == "running")
        #expect(plan.records.first { $0.operationID == "op-del" }?.state == "deleted")
        #expect(DaemonRecovery.preservedVolumes([volume.path]) == [volume.path])
        let driver = RecordingWorkloadSocketDriver()
        let store = MemoryOperationStore()
        let session = LocalManagementSession(
            policy: LocalManagementPolicy(
                allowedPeerUIDs: [1_000],
                memberships: [
                    MembershipFact(subject: "device-a", sessionToken: "token-a", revoked: false),
                ],
                resources: ResourcePolicy(allowedRoots: [], allowedMounts: [], allowedDevices: []),
            ),
            operationStore: store,
            workloadDriver: driver,
        )
        let peer = LocalPeerIdentity(uid: 1_000, gid: 1_000, pid: 7)
        let rejected = await session.handle(
            peer: peer,
            request: LocalManagementRequest(
                requestId: "req-schema",
                operationId: "op-schema",
                name: "workload.start",
                sessionToken: "token-a",
                workloadID: "vm-9",
                schemaVersion: 99,
            ),
        )
        #expect(rejected.rejection == LocalRejection.unsupportedProtocol.rawValue)
        #expect(await store.find(operationID: "op-schema") == nil)
        #expect(driver.calls.isEmpty)
        #expect(await session.effectCount() == 0)
    }

    @Test func `host network rollback while the server is down keeps the operation id`() throws {
        let pending = HostNetworkPendingCommit(
            target: "br0",
            commitDeadline: Date().addingTimeInterval(30),
            rollbackSeconds: 30,
            operationID: "op-net",
        )
        let box = RollbackCount()
        let confirmation = try HostNetworkDaemonRollback.rollbackWhileServerDown(
            pending: pending,
            serverAvailable: false,
            requestedOperationID: "op-net",
            revert: { _ in box.count += 1 },
        )
        #expect(confirmation.operationID == "op-net")
        #expect(confirmation.target == "br0")
        #expect(box.count == 1)
        #expect(throws: LocalManagementError.malformed) {
            try HostNetworkDaemonRollback.rollbackWhileServerDown(
                pending: pending,
                serverAvailable: false,
                requestedOperationID: "other-op",
                revert: { _ in box.count += 1 },
            )
        }
        #expect(box.count == 1)
        #expect(throws: LocalManagementError.malformed) {
            try HostNetworkDaemonRollback.rollbackWhileServerDown(
                pending: pending,
                serverAvailable: true,
                requestedOperationID: "op-net",
                revert: { _ in box.count += 1 },
            )
        }
        #expect(box.count == 1)
    }

    private func record(
        id: String,
        workload: String,
        kind: String,
        phase: String,
        state: String,
    ) -> DurableWorkloadOperation {
        DurableWorkloadOperation(
            operationID: id,
            workloadID: workload,
            subject: "device-a",
            kind: kind,
            phase: phase,
            state: state,
            runtime: "qemu",
            events: [],
            sequence: 1,
        )
    }
}

private final class RollbackCount: @unchecked Sendable {
    var count = 0
}
