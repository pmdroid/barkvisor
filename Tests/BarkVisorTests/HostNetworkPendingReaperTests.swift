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
        // Settled by the stamp rather than left waiting, so retention can prune it.
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.confirmed)
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

    /// An older confirmed record shares the same fixed `90-barkvisor-br0.*` paths, because
    /// every bridge snapshot claims them. Blocking on it would leave the expired bridge
    /// configured forever: only a newer claim can supersede this pending.
    @Test func `an older confirmed record does not block an expired pending`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        // Stands in for the fixed unit every bridge snapshot claims.
        let shared = root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.network")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "shared".write(to: shared, atomically: true, encoding: .utf8)

        // br0 applied and was confirmed earlier.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br0",
            generation: 1,
            target: "br0",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(-120),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-300),
        )
        try HostNetworkRecovery.mark("op-br0", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)

        // br1 then applied, never confirmed, and has expired.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br1",
            generation: 1,
            target: "br1",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-120),
        )
        try HostNetworkPendingCommitService.write(
            HostNetworkPendingCommit(
                target: "br1",
                commitDeadline: Date().addingTimeInterval(-5),
                rollbackSeconds: 60,
                operationId: "op-br1",
                generation: 1,
            ),
            to: HostNetworkPendingCommitService.linuxPendingPath(bridge: "br1", dataDir: data),
        )

        let pending = try #require(
            HostNetworkPendingReaper.pendingWithoutStamp(dataDir: data).first { $0.operationId == "op-br1" },
        )
        #expect(!HostNetworkPendingReaper.hostMutationBlocked(pending, records: HostNetworkRecovery.list(dataDir: data)))

        let reverts = RevertRecorder()
        await HostNetworkPendingReaper.expire(
            db: pool,
            dataDir: data,
            options: HostNetworkReapOptions(revertHost: reverts.record),
        )
        #expect(reverts.targets == ["br1"])
    }

    /// The ownership re-check and the revert share one exclusion with applies, in the same
    /// lock order an apply uses. A concurrent apply on another target must not be able to
    /// write a record and its files in between and then have them deleted.
    @Test func `a concurrent apply cannot interleave between the check and a pending revert`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let shared = root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.network")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "shared".write(to: shared, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br1",
            generation: 1,
            target: "br1",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-120),
        )
        try HostNetworkPendingCommitService.write(
            HostNetworkPendingCommit(
                target: "br1",
                commitDeadline: Date().addingTimeInterval(-5),
                rollbackSeconds: 60,
                operationId: "op-br1",
                generation: 1,
            ),
            to: HostNetworkPendingCommitService.linuxPendingPath(bridge: "br1", dataDir: data),
        )

        // A concurrent apply on another target holds the gate, then records a newer claim
        // and writes the shared unit, as LinuxHostBridgeApplyLive does.
        let holdsGate = DispatchSemaphore(value: 0)
        let mayRelease = DispatchSemaphore(value: 0)
        let applyDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? HostNetworkPendingCommitService.withApplyGate {
                holdsGate.signal()
                mayRelease.wait()
                try? HostNetworkRecovery.begin(
                    operationId: "op-br2",
                    generation: 1,
                    target: "br2",
                    snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
                    deadline: Date().addingTimeInterval(60),
                    dataDir: data,
                    startedAt: Date(),
                )
                try? "confirmed-by-br2".write(to: shared, atomically: true, encoding: .utf8)
            }
            applyDone.signal()
        }
        #expect(holdsGate.wait(timeout: .now() + 30) == .success)

        let reverts = RevertRecorder()
        let sweepDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Task {
                await HostNetworkPendingReaper.expire(
                    db: pool,
                    dataDir: data,
                    options: HostNetworkReapOptions(revertHost: reverts.record),
                )
                sweepDone.signal()
            }
        }
        // The reap is blocked on the gate the concurrent apply holds.
        #expect(sweepDone.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(reverts.targets.isEmpty)

        mayRelease.signal()
        #expect(applyDone.wait(timeout: .now() + 30) == .success)
        #expect(sweepDone.wait(timeout: .now() + 30) == .success)
        // The reap woke up, re-read ownership inside the gate, and found br2 newer.
        #expect(reverts.targets.isEmpty)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "confirmed-by-br2")
    }

    /// Another process holding the target's revert claim must leave the expired record
    /// retryable. The reaper's exclusion returns false in that case, and the sweep must not
    /// record a restore that never ran: that would suppress the retry permanently and
    /// leave the expired host configuration in place.
    @Test func `a claim held by another process leaves the record retryable`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try tempPool()
        try "before".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "applied".write(to: file, atomically: true, encoding: .utf8)

        // A live foreign process owns the claim, so claimRevert refuses it.
        let claim = URL(
            fileURLWithPath: HostNetworkPendingCommitService.claimPath("eth0", dataDir: data),
        )
        try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: true)
        try "1".write(to: claim.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try "1".write(to: claim.appendingPathComponent("refs"), atomically: true, encoding: .utf8)
        #expect(!HostNetworkPendingCommitService.claimRevert("eth0", dataDir: data))

        let reverts = RevertRecorder()
        await HostNetworkPendingReaper.expire(
            db: pool,
            dataDir: data,
            options: HostNetworkReapOptions(revertHost: reverts.record),
        )
        #expect(reverts.targets.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "applied")
        let record = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(record?.phase != HostNetworkRecoveryPhase.restored)
        #expect(record?.restoredAt == nil)
        #expect(record.map { !HostNetworkRecoveryPhase.isTerminal($0.phase) } == true)

        // Once the other holder is gone the sweep restores it.
        try? FileManager.default.removeItem(at: claim)
        await HostNetworkPendingReaper.expire(
            db: pool,
            dataDir: data,
            options: HostNetworkReapOptions(revertHost: reverts.record),
        )
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.restored)
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
