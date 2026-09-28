import Foundation
import Testing
@testable import BarkVisorCore

/// Who owns what a host network apply may write, and how long that ownership is kept.
///
/// Ownership is per claim, not per target: a Linux bridge snapshot always contains the
/// shared `/etc/systemd/network/90-barkvisor-*` units, so two targets can claim the same
/// files. Each test here reproduces a way a stale snapshot could have overwritten newer
/// configuration.
struct HostNetworkRecoveryOwnershipTests {
    @Test func `an expired record is superseded by a newer confirmed operation`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(-5)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 2,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: deadline,
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)
        // A newer operation applies and confirms the same path.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-new",
            generation: 3,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
        )
        try HostNetworkRecovery.mark("op-new", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        try "confirmed-config".write(to: file, atomically: true, encoding: .utf8)

        // The audit's exact reproduction: the old snapshot must not overwrite the newer
        // configuration.
        let first = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(first.restored.isEmpty)
        #expect(first.superseded == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "confirmed-config")
        // The superseded record is terminal, so no later sweep touches the path again.
        for _ in 0 ..< 3 {
            #expect(HostNetworkRecovery.sweepExpired(dataDir: data, now: Date()).isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "confirmed-config")
        }
        let record = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(record?.phase == HostNetworkRecoveryPhase.superseded)
        #expect(record?.restoredAt == nil)
        #expect(HostNetworkRecoveryPhase.isTerminal(HostNetworkRecoveryPhase.superseded))
    }

    /// A Linux bridge snapshot always captures the shared `90-barkvisor-br0.*` units, so two
    /// different targets claim the same files. A record whose restore keeps failing for
    /// target br0 must not retry its snapshot over target br1's confirmed configuration.
    @Test func `a retrying record never overwrites shared paths owned by another target`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let shared = root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.network")
        let own = root.appendingPathComponent("etc/netplan/br0.yaml")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: own.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try "shared-before-a".write(to: shared, atomically: true, encoding: .utf8)
        try "own-before-a".write(to: own, atomically: true, encoding: .utf8)

        // Target br0 expires and its restore fails.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br0",
            generation: 1,
            target: "br0",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path, own.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "shared-after-a".write(to: shared, atomically: true, encoding: .utf8)
        let failed = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                restore: { _ in throw BarkVisorError.internalError("restore failed") },
            ),
        )
        #expect(failed.failed == ["op-br0"])

        // Target br1 then applies and confirms, rewriting the same shared unit.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br1",
            generation: 1,
            target: "br1",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
        )
        try HostNetworkRecovery.mark("op-br1", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        try "shared-by-br1".write(to: shared, atomically: true, encoding: .utf8)

        // br0's retry has no br0 stamp and no br0 pending commit, but it still claims a path
        // br1 owns, so it must not write it.
        let first = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(first.superseded == ["op-br0"])
        #expect(first.restored.isEmpty)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "shared-by-br1")
        for _ in 0 ..< 2 {
            #expect(HostNetworkRecovery.sweepExpired(dataDir: data, now: Date()).isEmpty)
            #expect(try String(contentsOf: shared, encoding: .utf8) == "shared-by-br1")
        }
    }

    /// `request.generation ?? 1` means two ordinary applies on one target both record
    /// generation 1, so generation alone cannot order them.
    @Test func `successive applies that send no generation are still ordered`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        // Two applies, both generation 1, exactly as production records them. Their ids sort
        // in the opposite order to the applies, so a sweep that falls back to the id picks
        // the *older* record as the owner.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-zzz-older",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-120),
        )
        try "first-apply".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-aaa-newer",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-60),
        )
        try HostNetworkRecovery.mark("op-aaa-newer", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        try "second-confirmed".write(to: file, atomically: true, encoding: .utf8)

        // Clearing the target stamp for a later apply is what used to let the old record
        // back in as the computed owner.
        let first = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(first.superseded == ["op-zzz-older"])
        #expect(first.restored.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "second-confirmed")
        for _ in 0 ..< 2 {
            #expect(HostNetworkRecovery.sweepExpired(dataDir: data, now: Date()).isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "second-confirmed")
        }
    }

    /// The ownership re-check and the host write must share one exclusion, or a concurrent
    /// apply on an overlapping target can write the shared file in between and be undone by
    /// the older snapshot. Re-reading the records alone still leaves that window.
    @Test func `a concurrent apply on an overlapping target cannot interleave with a restore`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let shared = root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.network")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try "shared-before".write(to: shared, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br0",
            generation: 1,
            target: "br0",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-120),
        )
        try "applied-by-br0".write(to: shared, atomically: true, encoding: .utf8)

        // Stand in for a host network apply: hold the gate every apply holds, then save a
        // newer record and write the shared file, as LinuxHostBridgeApplyLive does.
        let holdsGate = DispatchSemaphore(value: 0)
        let mayRelease = DispatchSemaphore(value: 0)
        let applyFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? HostNetworkPendingCommitService.withApplyGate {
                holdsGate.signal()
                mayRelease.wait()
                try? HostNetworkRecovery.begin(
                    operationId: "op-br1",
                    generation: 1,
                    target: "br1",
                    snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
                    deadline: Date().addingTimeInterval(60),
                    dataDir: data,
                    startedAt: Date(),
                )
                try? "confirmed-by-br1".write(to: shared, atomically: true, encoding: .utf8)
            }
            applyFinished.signal()
        }
        #expect(holdsGate.wait(timeout: .now() + 30) == .success)

        // The sweep must not restore while the apply holds the gate.
        let probe = RestoreProbe()
        let sweepFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let result = HostNetworkRecovery.sweepExpired(
                dataDir: data,
                now: Date(),
                options: HostNetworkRecoverySweepOptions(restore: probe.restore),
            )
            probe.record(result)
            sweepFinished.signal()
        }
        // The sweep is blocked on the gate the apply holds.
        #expect(sweepFinished.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(probe.restoreCount == 0)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "applied-by-br0")

        mayRelease.signal()
        #expect(applyFinished.wait(timeout: .now() + 30) == .success)
        #expect(sweepFinished.wait(timeout: .now() + 30) == .success)
        #expect(probe.restoreCount == 0)
        // The sweep woke up, re-read ownership inside the gate, found br1 newer, and left
        // br1's configuration alone.
        #expect(probe.result?.restored.isEmpty == true)
        #expect(probe.result?.superseded == ["op-br0"])
        #expect(try String(contentsOf: shared, encoding: .utf8) == "confirmed-by-br1")
    }

    /// `generation` comes from each request, so an old br0 record can carry generation 2
    /// while a much newer br1 record carries 1. Comparing generations across targets would
    /// hand the older apply the win over the shared networkd files.
    @Test func `apply order across targets ignores per-request generations`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let shared = root.appendingPathComponent("etc/systemd/network/90-barkvisor-br0.network")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try "shared-before".write(to: shared, atomically: true, encoding: .utf8)

        // The older apply on br0 recorded a higher generation than the newer one on br1.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-br0",
            generation: 2,
            target: "br0",
            snapshot: HostNetworkRecovery.capture(paths: [shared.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-120),
        )
        try "applied-by-br0".write(to: shared, atomically: true, encoding: .utf8)
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

        let first = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(first.superseded == ["op-br0"])
        #expect(first.restored.isEmpty)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "confirmed-by-br1")
        for _ in 0 ..< 2 {
            #expect(HostNetworkRecovery.sweepExpired(dataDir: data, now: Date()).isEmpty)
            #expect(try String(contentsOf: shared, encoding: .utf8) == "confirmed-by-br1")
        }
    }

    /// Pruning the terminal record removed the only ownership evidence, so a surviving
    /// `restore_failed` record became the owner once the stamp was cleared.
    @Test func `retention keeps the ownership evidence a retrying record still needs`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let longAgo = Date().addingTimeInterval(-30 * HostNetworkRecovery.terminalRetention)
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        // The older record keeps failing to restore.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-stuck",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: longAgo,
            dataDir: data,
            startedAt: longAgo,
        )
        // A newer apply confirmed long ago, so its record is past the retention window.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-owner",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: longAgo,
            dataDir: data,
            startedAt: longAgo.addingTimeInterval(60),
        )
        try HostNetworkRecovery.mark("op-owner", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        var owner = try #require(HostNetworkRecovery.load(operationId: "op-owner", dataDir: data))
        owner.restoredAt = longAgo.addingTimeInterval(60)
        try HostNetworkRecovery.save(owner, dataDir: data)
        try "owned-config".write(to: file, atomically: true, encoding: .utf8)

        // The owner is past retention, but it is the only evidence that the stuck record
        // lost ownership, so it survives and the stuck record stays superseded.
        #expect(HostNetworkRecovery.prune(dataDir: data, now: Date()).isEmpty)
        let swept = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(swept.superseded == ["op-stuck"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "owned-config")
    }

    @Test func `an unsettled record keeps the settled records that outrank it`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settled = Date().addingTimeInterval(-2 * HostNetworkRecovery.terminalRetention)
        // Settled, past retention, and on the same target as a record that is still moving.
        try HostNetworkRecovery.save(
            HostNetworkRecoveryRecord(
                operationId: "op-old-owner",
                generation: 1,
                target: "eth0",
                phase: HostNetworkRecoveryPhase.confirmed,
                deadline: settled,
                snapshot: HostNetworkSnapshot(),
                restoredAt: settled,
            ),
            dataDir: data,
        )
        // Settled and past retention, but on a target nothing else touches.
        try HostNetworkRecovery.save(
            HostNetworkRecoveryRecord(
                operationId: "op-unrelated",
                generation: 1,
                target: "eth1",
                phase: HostNetworkRecoveryPhase.restored,
                deadline: settled,
                snapshot: HostNetworkSnapshot(),
                restoredAt: settled,
            ),
            dataDir: data,
        )
        _ = try HostNetworkRecovery.begin(
            operationId: "op-unsettled",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkSnapshot(),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: settled,
        )
        // Only the record no unsettled record depends on is pruned.
        #expect(HostNetworkRecovery.prune(dataDir: data, now: Date()) == ["op-unrelated"])
        #expect(Set(HostNetworkRecovery.list(dataDir: data).map(\.operationId))
            == ["op-old-owner", "op-unsettled"])
    }

    @Test func `terminal records are pruned once the retention window passes`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settled = Date().addingTimeInterval(-2 * HostNetworkRecovery.terminalRetention)
        for (id, phase) in [
            ("op-restored", HostNetworkRecoveryPhase.restored),
            ("op-superseded", HostNetworkRecoveryPhase.superseded),
            ("op-legacy", HostNetworkRecoveryPhase.legacyReverting),
        ] {
            try HostNetworkRecovery.save(
                HostNetworkRecoveryRecord(
                    operationId: id,
                    generation: 1,
                    target: "eth0",
                    phase: phase,
                    deadline: settled,
                    snapshot: HostNetworkSnapshot(),
                    restoredAt: settled,
                ),
                dataDir: data,
            )
        }
        // Nothing unsettled shares eth0, so the settled records go and `list()` stays bounded.
        #expect(HostNetworkRecovery.list(dataDir: data).count == 3)
        #expect(HostNetworkRecovery.prune(dataDir: data, now: Date()).sorted()
            == ["op-legacy", "op-restored", "op-superseded"])
        #expect(HostNetworkRecovery.list(dataDir: data).isEmpty)
        // A late confirmation for a pruned record still gets a meaningful answer.
        #expect(throws: BarkVisorError.self) {
            try HostNetworkRecovery.requireConfirmation(
                pending: HostNetworkPendingCommit(
                    target: "eth0",
                    commitDeadline: Date().addingTimeInterval(60),
                    rollbackSeconds: 60,
                    operationId: "op-restored",
                    generation: 1,
                ),
                requestedOperationId: "op-restored",
                requestedGeneration: 1,
                authorized: true,
                now: Date(),
                dataDir: data,
            )
        }
    }

    /// Records what a sweep did, across the thread the sweep runs on.
    private final class RestoreProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var restores = 0
        private var outcome: HostNetworkRecoverySweepResult?

        var restoreCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return restores
        }

        var result: HostNetworkRecoverySweepResult? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }

        func restore(_ snapshot: HostNetworkSnapshot) throws {
            lock.lock()
            restores += 1
            lock.unlock()
            try HostNetworkRecovery.restore(snapshot)
        }

        func record(_ result: HostNetworkRecoverySweepResult) {
            lock.lock()
            outcome = result
            lock.unlock()
        }
    }
}
