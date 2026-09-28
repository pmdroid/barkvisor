import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// The reaper sweep runs every two seconds and on startup, so anything it writes to a
/// host network path has to be ownership-checked and terminal. Temp directories only:
/// these tests never touch a real bridge, route or interface.
struct HostNetworkPendingReaperTests {
    @Test func `a newer confirmed operation is never overwritten by an expired record`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)

        // The audit's exact reproduction: expire an old operation, apply and confirm a
        // newer one on the same path, sweep again.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 2,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "applied-by-old".write(to: file, atomically: true, encoding: .utf8)
        await HostNetworkPendingReaper.expire(db: pool, dataDir: data)
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.restored)

        _ = try HostNetworkRecovery.begin(
            operationId: "op-new",
            generation: 3,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
        )
        try HostNetworkRecovery.mark("op-new", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        try "confirmed-by-new".write(to: file, atomically: true, encoding: .utf8)

        for _ in 0 ..< 3 {
            await HostNetworkPendingReaper.expire(db: pool, dataDir: data)
            #expect(try String(contentsOf: file, encoding: .utf8) == "confirmed-by-new")
        }
    }

    @Test func `a stale record does not restore while a pending commit owns the target`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "pending-apply".write(to: file, atomically: true, encoding: .utf8)
        let pending = HostNetworkPendingCommit(
            target: "eth0",
            commitDeadline: Date().addingTimeInterval(60),
            rollbackSeconds: 60,
            operationId: "op-live",
            generation: 2,
        )
        try HostNetworkPendingCommitService.write(
            pending,
            to: HostNetworkPendingCommitService.linuxPendingPath(bridge: "eth0", dataDir: data),
        )

        await HostNetworkPendingReaper.expire(db: pool, dataDir: data)
        #expect(try String(contentsOf: file, encoding: .utf8) == "pending-apply")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.mutating)
    }

    @Test func `a record with no pending commit is still swept`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-orphan",
            generation: 1,
            target: "br9",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "applied".write(to: file, atomically: true, encoding: .utf8)
        // No pending commit file exists at all; the record's own target must still be swept.
        #expect(HostNetworkPendingReaper.pendingWithoutStamp(dataDir: data).isEmpty)
        await HostNetworkPendingReaper.expire(db: pool, dataDir: data)
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        #expect(HostNetworkRecovery.load(operationId: "op-orphan", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.restored)
    }

    @Test func `a commit stamp keeps the sweep from restoring`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth1",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "kept".write(to: file, atomically: true, encoding: .utf8)
        let stamp = URL(
            fileURLWithPath: LinuxHostBridgeApply.commitStampPath(bridge: "eth1", dataDir: data),
        )
        try FileManager.default.createDirectory(
            at: stamp.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data().write(to: stamp, options: .atomic)

        await HostNetworkPendingReaper.expire(db: pool, dataDir: data)
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.mutating)
    }

    /// An expired pending commit outlives a newer apply: the pending file is replaced when
    /// the newer apply runs, so nothing else stops the older revert. On systemd-networkd
    /// that revert deletes `90-barkvisor-<bridge>.network` and the shared uplink unit, and
    /// every bridge snapshot also claims the fixed `90-barkvisor-br0.*` units, so it can
    /// delete files the newer apply owns. The record sweep runs afterwards and cannot
    /// restore a deleted file.
    @Test func `an expired pending does not revert paths a newer operation owns`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        // Stands in for the shared units a systemd-networkd revert removes.
        let shared = root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.network")
        let uplink = root.appendingPathComponent("etc/systemd/network/90-barkvisor-enp3s0.network")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "shared-before".write(to: shared, atomically: true, encoding: .utf8)
        try "uplink-before".write(to: uplink, atomically: true, encoding: .utf8)

        // The expired operation on br0, which captured the shared units.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br0",
            generation: 1,
            target: "br0",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path, uplink.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-120),
        )
        try HostNetworkPendingCommitService.write(
            HostNetworkPendingCommit(
                target: "br0",
                commitDeadline: Date().addingTimeInterval(-5),
                rollbackSeconds: 60,
                operationId: "op-br0",
                generation: 1,
            ),
            to: HostNetworkPendingCommitService.linuxPendingPath(bridge: "br0", dataDir: data),
        )
        try "applied-by-br0".write(to: shared, atomically: true, encoding: .utf8)

        // A newer apply on br1 applies and confirms, claiming the same shared unit.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br1",
            generation: 1,
            target: "br1",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-60),
        )
        try HostNetworkRecovery.mark("op-br1", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        try "confirmed-by-br1".write(to: shared, atomically: true, encoding: .utf8)

        let records = HostNetworkRecovery.list(dataDir: data)
        let expiredPending = try #require(
            HostNetworkPendingReaper.pendingWithoutStamp(dataDir: data)
                .first { $0.operationId == "op-br0" },
        )
        // The decision is the guarantee: the real revert would delete host files, so it
        // cannot be executed in a test.
        #expect(HostNetworkPendingReaper.hostMutationBlocked(expiredPending, records: records))
        // With no competitor the revert still runs, so expiry is not disabled.
        #expect(!HostNetworkPendingReaper.hostMutationBlocked(expiredPending, records: []))

        // Whether the reaper actually decided to revert is the observable behaviour. The
        // real revert is stubbed, because it would delete host files and a test cannot run
        // it; `requireHostMutation` would throw first anyway and hide the call.
        let reverts = RevertRecorder()
        await HostNetworkPendingReaper.expire(
            db: pool,
            dataDir: data,
            options: HostNetworkReapOptions(revertHost: reverts.record),
        )
        #expect(reverts.targets.isEmpty)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "confirmed-by-br1")
        #expect(try String(contentsOf: uplink, encoding: .utf8) == "uplink-before")
        #expect(HostNetworkRecovery.load(operationId: "op-br0", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.superseded)
    }

    /// The same expired pending, with no newer operation to block it, still reverts. Guards
    /// against "fixing" the overlap by never reverting anything.
    @Test func `an expired pending with no competitor still reverts`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        _ = try HostNetworkRecovery.begin(
            operationId: "op-solo",
            generation: 1,
            target: "br0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try HostNetworkPendingCommitService.write(
            HostNetworkPendingCommit(
                target: "br0",
                commitDeadline: Date().addingTimeInterval(-5),
                rollbackSeconds: 60,
                operationId: "op-solo",
                generation: 1,
            ),
            to: HostNetworkPendingCommitService.linuxPendingPath(bridge: "br0", dataDir: data),
        )
        let reverts = RevertRecorder()
        await HostNetworkPendingReaper.expire(
            db: pool,
            dataDir: data,
            options: HostNetworkReapOptions(revertHost: reverts.record),
        )
        #expect(reverts.targets == ["br0"])
    }

    @Test func `only expired work claims a gate`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A live pending commit and an unexpired record stay out of the two-second sweep.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-live",
            generation: 1,
            target: "target-from-live-record",
            snapshot: HostNetworkSnapshot(),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
        )
        try HostNetworkPendingCommitService.write(
            HostNetworkPendingCommit(
                target: "target-from-live-pending",
                commitDeadline: Date().addingTimeInterval(60),
                rollbackSeconds: 60,
            ),
            to: HostNetworkPendingCommitService.linuxPendingPath(bridge: "target-from-live-pending", dataDir: data),
        )
        #expect(
            HostNetworkPendingReaper.expireTargets(
                pendings: HostNetworkPendingReaper.pendingWithoutStamp(dataDir: data),
                records: HostNetworkRecovery.list(dataDir: data),
            ).isEmpty,
        )

        // Expired work on either side does claim its target.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-expired",
            generation: 1,
            target: "target-from-expired-record",
            snapshot: HostNetworkSnapshot(),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try HostNetworkPendingCommitService.write(
            HostNetworkPendingCommit(
                target: "target-from-expired-pending",
                commitDeadline: Date().addingTimeInterval(-5),
                rollbackSeconds: 60,
            ),
            to: HostNetworkPendingCommitService.linuxPendingPath(
                bridge: "target-from-expired-pending",
                dataDir: data,
            ),
        )
        #expect(
            HostNetworkPendingReaper.expireTargets(
                pendings: HostNetworkPendingReaper.pendingWithoutStamp(dataDir: data),
                records: HostNetworkRecovery.list(dataDir: data),
            ).sorted() == ["target-from-expired-pending", "target-from-expired-record"],
        )
    }

    @Test func `a settled record claims no gate`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, phase) in [
            ("op-restored", HostNetworkRecoveryPhase.restored),
            ("op-superseded", HostNetworkRecoveryPhase.superseded),
            ("op-confirmed", HostNetworkRecoveryPhase.confirmed),
        ] {
            _ = try HostNetworkRecovery.begin(
                operationId: id,
                generation: 1,
                target: "settled-target",
                snapshot: HostNetworkSnapshot(),
                deadline: Date().addingTimeInterval(-5),
                dataDir: data,
            )
            try HostNetworkRecovery.mark(id, phase: phase, dataDir: data)
        }
        #expect(
            HostNetworkPendingReaper.expireTargets(
                pendings: [],
                records: HostNetworkRecovery.list(dataDir: data),
            ).isEmpty,
        )
    }

    /// Records which targets the reaper decided to revert, across threads.
    private final class RevertRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        var targets: [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func record(_ pending: HostNetworkPendingCommit, _ attached: Int) throws {
            lock.lock()
            seen.append(pending.target)
            lock.unlock()
        }
    }

    private func tempPool() throws -> DatabasePool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-net-reaper-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: path.path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }
}
