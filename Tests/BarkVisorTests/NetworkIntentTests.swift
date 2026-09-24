import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct NetworkIntentTests {
    @Test func `compose keeps an interface bind and rejects guest virtual DNS`() throws {
        let yaml = """
        services:
          web:
            image: traefik/whoami
            ports:
              - "192.0.2.10:8080:80"
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let render = try ComposeAllowlist.render(
            yaml: yaml,
            workloadID: "web",
            stateDir: dir,
            bindHost: "0.0.0.0",
            upstreamResolver: "9.9.9.9",
        )
        #expect(render.publishedPorts.first?.hostAddress == "192.0.2.10")
        #expect(render.yaml.contains("192.0.2.10"))
        #expect(render.yaml.contains("9.9.9.9"))
        let rejected = #expect(throws: BarkVisorError.self) {
            _ = try ComposeAllowlist.render(
                yaml: yaml,
                workloadID: "web",
                stateDir: dir,
                guestDNS: "10.0.2.3",
            )
        }
        #expect(rejected != nil)
    }

    @Test func `claims distinguish family protocol and wildcard`() throws {
        let loopback = try NetworkIntent.publication(
            bindAddress: "127.0.0.1", proto: "tcp", publishedPort: 80, targetPort: 80,
        )
        let other = try NetworkIntent.publication(
            bindAddress: "192.0.2.8", proto: "tcp", publishedPort: 80, targetPort: 80,
        )
        let wildcard = try NetworkIntent.publication(
            bindAddress: "0.0.0.0", proto: "tcp", publishedPort: 80, targetPort: 80,
        )
        let udp = try NetworkIntent.publication(
            bindAddress: "127.0.0.1", proto: "udp", publishedPort: 80, targetPort: 80,
        )
        let v6 = try NetworkIntent.publication(
            bindAddress: "::1", proto: "tcp", publishedPort: 80, targetPort: 80,
        )
        let v6Any = try NetworkIntent.publication(
            bindAddress: "::", proto: "tcp", publishedPort: 80, targetPort: 80,
        )
        #expect(!NetworkIntentBinding.overlaps(loopback, other))
        #expect(NetworkIntentBinding.overlaps(loopback, wildcard))
        #expect(!NetworkIntentBinding.overlaps(loopback, udp))
        #expect(!NetworkIntentBinding.overlaps(loopback, v6))
        #expect(NetworkIntentBinding.overlaps(loopback, v6Any))
        #expect(NetworkIntentBinding.overlaps(v6, v6Any))
    }

    @Test func `a failed claim releases only its own reservation`() throws {
        let pool = try tempPool()
        let held = try NetworkIntent.publication(
            bindAddress: "127.0.0.1", proto: "tcp", publishedPort: 9_090, targetPort: 80,
        )
        let stolen = try NetworkIntent.publication(
            bindAddress: "0.0.0.0", proto: "tcp", publishedPort: 9_090, targetPort: 80,
        )
        try pool.write { db in
            try PortClaimStore.claim(
                [PortReservation(operationId: "op-a", workloadKind: "vm", workloadId: "vm-a", publication: held)],
                operationId: "op-a",
                workloadId: "vm-a",
                db: db,
            )
        }
        _ = try pool.write { db in
            #expect(throws: BarkVisorError.self) {
                try PortClaimStore.claim(
                    [PortReservation(
                        operationId: "op-b", workloadKind: "workload", workloadId: "app-b", publication: stolen,
                    )],
                    operationId: "op-b",
                    workloadId: "app-b",
                    db: db,
                )
            }
        }
        let afterFailure = try pool.read { db in try PortClaimStore.listed(db: db) }
        #expect(afterFailure.count == 1)
        #expect(afterFailure[0].operationId == "op-a")
        let released = try pool.write { db in
            try PortClaimStore.release(operationId: "op-b", workloadId: "app-b", db: db)
        }
        #expect(released == 0)
        let still = try pool.read { db in try PortClaimStore.listed(db: db) }
        #expect(still.count == 1)
        _ = try pool.write { db in
            try PortClaimStore.release(operationId: "op-a", workloadId: "vm-a", db: db)
        }
        let gone = try pool.read { db in try PortClaimStore.listed(db: db) }
        #expect(gone.isEmpty)
    }

    @Test func `ipv6 specific claim does not steal an ipv4 reservation`() throws {
        let pool = try tempPool()
        let v4 = try NetworkIntent.publication(
            bindAddress: "127.0.0.1", proto: "tcp", publishedPort: 7_070, targetPort: 70,
        )
        let v6 = try NetworkIntent.publication(
            bindAddress: "::1", proto: "tcp", publishedPort: 7_070, targetPort: 70,
        )
        try pool.write { db in
            try PortClaimStore.claim(
                [PortReservation(operationId: "op-v4", workloadKind: "vm", workloadId: "vm-v4", publication: v4)],
                operationId: "op-v4",
                workloadId: "vm-v4",
                db: db,
            )
            try PortClaimStore.claim(
                [PortReservation(operationId: "op-v6", workloadKind: "workload", workloadId: "app-v6", publication: v6)],
                operationId: "op-v6",
                workloadId: "app-v6",
                db: db,
            )
        }
        let rows = try pool.read { db in try PortClaimStore.listed(db: db) }
        #expect(rows.count == 2)
    }

    @Test func `expired unconfirmed recovery restores the snapshot`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = HostNetworkRecovery.capture(paths: [file.path])
        let deadline = Date().addingTimeInterval(-5)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 2,
            target: "eth0",
            snapshot: snapshot,
            deadline: deadline,
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)
        let pending = HostNetworkPendingCommit(
            target: "eth0",
            commitDeadline: deadline,
            rollbackSeconds: 60,
            operationId: "op-old",
            generation: 2,
        )
        #expect(throws: BarkVisorError.self) {
            try HostNetworkRecovery.requireConfirmation(
                pending: pending,
                requestedOperationId: "op-old",
                requestedGeneration: 2,
                authorized: true,
                now: Date(),
                dataDir: data,
            )
        }
        let reverted = try HostNetworkRecovery.revertExpired(dataDir: data, now: Date())
        #expect(reverted == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        let record = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(record?.phase == HostNetworkRecoveryPhase.reverting)
        #expect(!PendingNetworkUsePolicy.attachmentConfirmsPending())
        #expect(PendingNetworkUsePolicy.expiryAction(attachedWorkloads: 3) == .revert)
        #expect(!PendingNetworkUsePolicy.usableWhileUnconfirmed())
    }

    @Test func `stale or unauthorized confirmation does not commit a newer operation`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deadline = Date().addingTimeInterval(60)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-new",
            generation: 4,
            target: "eth0",
            snapshot: HostNetworkSnapshot(),
            deadline: deadline,
            dataDir: root,
        )
        let pending = HostNetworkPendingCommit(
            target: "eth0",
            commitDeadline: deadline,
            rollbackSeconds: 60,
            operationId: "op-new",
            generation: 4,
        )
        #expect(throws: BarkVisorError.self) {
            try HostNetworkRecovery.requireConfirmation(
                pending: pending,
                requestedOperationId: "op-new",
                requestedGeneration: 3,
                authorized: true,
                now: Date(),
                dataDir: root,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HostNetworkRecovery.requireConfirmation(
                pending: pending,
                requestedOperationId: "op-old",
                requestedGeneration: 4,
                authorized: true,
                now: Date(),
                dataDir: root,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try HostNetworkRecovery.requireConfirmation(
                pending: pending,
                requestedOperationId: "op-new",
                requestedGeneration: 4,
                authorized: false,
                now: Date(),
                dataDir: root,
            )
        }
        try HostNetworkRecovery.requireConfirmation(
            pending: pending,
            requestedOperationId: nil,
            requestedGeneration: nil,
            authorized: true,
            now: Date(),
            dataDir: root,
        )
        try HostNetworkRecovery.requireConfirmation(
            pending: pending,
            requestedOperationId: "op-new",
            requestedGeneration: 4,
            authorized: true,
            now: Date(),
            dataDir: root,
        )
        try HostNetworkRecovery.mark("op-new", phase: HostNetworkRecoveryPhase.confirmed, dataDir: root)
        #expect(HostNetworkRecovery.load(operationId: "op-new", dataDir: root)?.phase == HostNetworkRecoveryPhase.confirmed)
    }

    private func tempPool() throws -> DatabasePool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-claims-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: path.path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }
}
