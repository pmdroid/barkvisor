import Foundation
import Testing
@testable import BarkVisorCore

/// The expired-record sweep: a settled snapshot is never re-applied, an expired record
/// never overwrites a newer owner, a failed restore stays retryable, and `list()` stays
/// bounded. Temp directories only.
struct HostNetworkRecoveryTests {
    @Test func `expired unconfirmed recovery restores the snapshot once`() throws {
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
        let swept = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(swept.restored == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        let record = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(record?.phase == HostNetworkRecoveryPhase.restored)
        #expect(record?.restoredAt != nil)
        #expect(HostNetworkRecoveryPhase.isTerminal(HostNetworkRecoveryPhase.restored))
        #expect(!PendingNetworkUsePolicy.attachmentConfirmsPending())
        #expect(PendingNetworkUsePolicy.expiryAction(attachedWorkloads: 3) == .revert)
        #expect(!PendingNetworkUsePolicy.usableWhileUnconfirmed())
    }

    @Test func `a restored snapshot is never re-applied by a later sweep`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(-5)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: deadline,
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)
        #expect(HostNetworkRecovery.sweepExpired(dataDir: data, now: Date()).restored == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        // A newer apply and confirm takes the path over, and the settled record stays
        // terminal, so the second sweep is a no-op.
        try "newer".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-new",
            generation: 2,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
        )
        try HostNetworkRecovery.mark("op-new", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        let second = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(second.isEmpty)
        #expect(second.restored.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "newer")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.restored)
    }

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

    /// A restore that succeeds but whose terminal phase cannot be persisted would be
    /// replayed on every later sweep. The sweep must report that instead of claiming
    /// success.
    @Test func `a restore whose terminal state cannot be persisted reports failure`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)

        // The data volume is full: every write to the record fails.
        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                persist: { _ in throw BarkVisorError.internalError("no space left on device") },
            ),
        )
        #expect(swept.failed == ["op-old"])
        #expect(swept.restored.isEmpty)
        // The snapshot did land on the host, but the sweep does not claim success.
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
    }

    /// The exclusion can decline to run the restore at all, when another holder owns the
    /// target's revert claim. The record must then stay retryable: reporting it restored
    /// would suppress the retry permanently and leave the expired host configuration in
    /// place, and the record sweep only restores files it captured, so nothing else undoes
    /// a restore that never happened.
    /// A commit lands while the sweep is queued for the target claim. The sweep's read-only
    /// checks all run before it waits, so it could pass them, take the claim afterwards and
    /// restore its old snapshot over configuration that was just kept. The stamp check is
    /// repeated inside the exclusion, where it is authoritative.
    @Test func `a commit stamp that lands while the sweep waits blocks the restore`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "kept".write(to: file, atomically: true, encoding: .utf8)
        let stamp = URL(fileURLWithPath: LinuxHostBridgeApply.commitStampPath(bridge: "eth0", dataDir: data))

        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                exclusive: { body in
                    // The stamp appears after the read-only checks ran, before the body.
                    try Data().write(to: stamp, options: .atomic)
                    try body()
                    return true
                },
            ),
        )
        #expect(swept.restored.isEmpty)
        // The stamp means this target's changes were kept, so the operation is settled
        // rather than left waiting: deferring here would keep the record unsettled forever,
        // and retention keeps every settled record an unsettled one depends on.
        #expect(swept.confirmed == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.confirmed)
    }

    /// A confirmation that marked the record `confirmed` while the sweep waited. Ownership
    /// cannot catch this: a record never outranks itself, so the in-gate re-read of the
    /// record's own phase is the only thing standing between the sweep and a restore that
    /// would overwrite the confirmed configuration and persist `restored`.
    @Test func `a record confirmed while the sweep waits is not restored`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "confirmed".write(to: file, atomically: true, encoding: .utf8)

        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                // A confirmation marks the record before it writes the stamp, so the record
                // is already terminal when the sweep's turn comes. No stamp here on purpose.
                exclusive: { body in
                    try HostNetworkRecovery.mark(
                        "op-old",
                        phase: HostNetworkRecoveryPhase.confirmed,
                        dataDir: data,
                    )
                    try body()
                    return true
                },
            ),
        )
        #expect(swept.restored.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "confirmed")
        let record = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(record?.phase == HostNetworkRecoveryPhase.confirmed)
        #expect(record?.restoredAt == nil)
    }

    /// A commit stamp is per target. On macOS a new apply does not clear the previous
    /// one's stamp, so a second unconfirmed apply inherits it. The stamp says nothing about
    /// the *new* operation's snapshot, and settling on it would skip a restore that is
    /// still owed, including after a restart.
    @Test func `a stamp from an earlier apply does not confirm a second one`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before".write(to: file, atomically: true, encoding: .utf8)

        // First apply on en0, confirmed. It leaves a stamp naming itself.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-first",
            generation: 1,
            target: "en0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-120),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-300),
        )
        try HostNetworkRecovery.mark("op-first", phase: HostNetworkRecoveryPhase.confirmed, dataDir: data)
        try HostNetworkPendingCommitService.writeCommitStamp(target: "en0", operationId: "op-first", dataDir: data)

        // Second apply on the same Device, never confirmed, and its pending commit expires.
        _ = try HostNetworkRecovery.begin(
            operationId: "op-second",
            generation: 1,
            target: "en0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
            startedAt: Date().addingTimeInterval(-60),
        )
        try "applied-by-second".write(to: file, atomically: true, encoding: .utf8)

        // Starting the second apply must not inherit the first one's confirmation.
        #expect(!HostNetworkPendingCommitService.stampExists("en0", dataDir: data))

        // With no stamp of its own, the expired second apply still owes a restore.
        let swept = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(swept.restored == ["op-second"])
        #expect(swept.confirmed.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
        #expect(HostNetworkRecovery.load(operationId: "op-second", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.restored)
    }

    /// The stamp names a *different* operation and is still on the target when the sweep
    /// runs, so the sweep has to read who wrote it. Pins that on its own: the companion
    /// test's stamp is cleared when the second apply begins, so it would pass here too.
    @Test func `a stamp naming another operation does not confirm this one`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before".write(to: file, atomically: true, encoding: .utf8)
        // Saved directly, so nothing clears the stamp on the way in.
        try HostNetworkRecovery.save(
            HostNetworkRecoveryRecord(
                operationId: "op-x",
                generation: 1,
                target: "en2",
                phase: HostNetworkRecoveryPhase.awaitingConfirmation,
                deadline: Date().addingTimeInterval(-5),
                snapshot: HostNetworkRecovery.capture(paths: [file.path]),
                startedAt: Date().addingTimeInterval(-120),
            ),
            dataDir: data,
        )
        try "applied-by-x".write(to: file, atomically: true, encoding: .utf8)
        try HostNetworkPendingCommitService.writeCommitStamp(target: "en2", operationId: "op-other", dataDir: data)
        #expect(HostNetworkPendingCommitService.stampExists("en2", dataDir: data))
        #expect(HostNetworkPendingCommitService.commitStampOwner("en2", dataDir: data) == "op-other")

        let swept = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(swept.restored == ["op-x"])
        #expect(swept.confirmed.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
    }

    /// A stamp written before ids were recorded cannot be attributed, and still confirms:
    /// an upgraded Device must not start reverting operations a user already kept.
    @Test func `a stamp with no recorded owner still confirms`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "en1",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "applied".write(to: file, atomically: true, encoding: .utf8)
        // A legacy, empty stamp.
        let stamp = URL(fileURLWithPath: LinuxHostBridgeApply.commitStampPath(bridge: "en1", dataDir: data))
        try FileManager.default.createDirectory(
            at: stamp.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data().write(to: stamp, options: .atomic)
        #expect(HostNetworkPendingCommitService.commitStampOwner("en1", dataDir: data) == nil)

        let swept = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(swept.confirmed == ["op-old"])
        #expect(swept.restored.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "applied")
    }

    @Test func `a declined exclusion leaves the record retryable`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)

        let restores = RestoreCount()
        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                restore: { snapshot in
                    restores.increment()
                    try HostNetworkRecovery.restore(snapshot)
                },
                // Stands in for another process holding the target's revert claim.
                exclusive: { _ in false },
            ),
        )
        #expect(swept.deferred == ["op-old"])
        #expect(swept.restored.isEmpty)
        #expect(swept.failed.isEmpty)
        #expect(!restores.didRestore)
        // Nothing was written at all, to the host or to the record: the phase change is
        // written inside the exclusion, so a declined body leaves the record untouched and
        // retryable.
        #expect(try String(contentsOf: file, encoding: .utf8) == "static")
        let record = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(record?.phase == HostNetworkRecoveryPhase.mutating)
        #expect(record?.restoredAt == nil)
        #expect(record.map { !HostNetworkRecoveryPhase.isTerminal($0.phase) } == true)

        // With the claim released, the very next sweep restores it.
        let retried = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(retried.restored == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
    }

    @Test func `a terminal write is retried before the sweep gives up`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)
        var terminalWrites = 0
        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                persist: { record in
                    // Fail until the record reaches its terminal phase, the way a transient
                    // full disk settles.
                    guard record.phase == HostNetworkRecoveryPhase.restored else {
                        throw BarkVisorError.internalError("no space left on device")
                    }
                    terminalWrites += 1
                    try HostNetworkRecovery.save(record, dataDir: data)
                },
            ),
        )
        #expect(swept.restored == ["op-old"])
        #expect(terminalWrites == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.restored)
    }

    @Test func `a stale record never writes a path a live pending commit owns`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "applied".write(to: file, atomically: true, encoding: .utf8)
        let live = HostNetworkPendingCommit(
            target: "eth0",
            commitDeadline: Date().addingTimeInterval(60),
            rollbackSeconds: 60,
        )
        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(pendingCommits: [live]),
        )
        #expect(swept.deferred == ["op-old"])
        #expect(swept.restored.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "applied")
        // A deferred record keeps its phase and stays retryable.
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.mutating)
    }

    @Test func `a commit stamp keeps a stale record from restoring`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "kept".write(to: file, atomically: true, encoding: .utf8)
        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(stampExists: { $0 == "eth0" }),
        )
        #expect(swept.confirmed == ["op-old"])
        #expect(swept.restored.isEmpty)
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.confirmed)
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
    }

    @Test func `a failed restore is retried on the next sweep and recorded`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "eth0",
            snapshot: HostNetworkRecovery.capture(paths: [file.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "static".write(to: file, atomically: true, encoding: .utf8)

        let failed = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                restore: { _ in throw BarkVisorError.internalError("snapshot write failed") },
            ),
        )
        #expect(failed.failed == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "static")
        let recorded = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(recorded?.phase == HostNetworkRecoveryPhase.restoreFailed)
        #expect(recorded?.restoreAttempts == 1)
        #expect(recorded?.lastRestoreError?.contains("snapshot write failed") == true)
        #expect(!HostNetworkRecoveryPhase.isTerminal(HostNetworkRecoveryPhase.restoreFailed))

        // The next sweep retries with the real file system and still succeeds.
        let retried = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(retried.restored == ["op-old"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "dhcp")
        let settled = HostNetworkRecovery.load(operationId: "op-old", dataDir: data)
        #expect(settled?.phase == HostNetworkRecoveryPhase.restored)
        #expect(settled?.restoreAttempts == 1)
        #expect(settled?.lastRestoreError == nil)
    }

    @Test func `one failed restore does not stop the rest of the sweep`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let broken = root.appendingPathComponent("broken.txt")
        let good = root.appendingPathComponent("good.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before-broken".write(to: broken, atomically: true, encoding: .utf8)
        try "before-good".write(to: good, atomically: true, encoding: .utf8)
        for (id, target, file) in [("op-broken", "eth0", broken), ("op-good", "eth1", good)] {
            _ = try HostNetworkRecovery.begin(
                operationId: id,
                generation: 1,
                target: target,
                snapshot: HostNetworkRecovery.capture(paths: [file.path]),
                deadline: Date().addingTimeInterval(-5),
                dataDir: data,
            )
            try "after".write(to: file, atomically: true, encoding: .utf8)
        }
        let swept = HostNetworkRecovery.sweepExpired(
            dataDir: data,
            now: Date(),
            options: HostNetworkRecoverySweepOptions(
                restore: { snapshot in
                    if snapshot.files.keys.contains(broken.path) {
                        throw BarkVisorError.internalError("snapshot write failed")
                    }
                    try HostNetworkRecovery.restore(snapshot)
                },
            ),
        )
        #expect(swept.failed == ["op-broken"])
        #expect(swept.restored == ["op-good"])
        #expect(try String(contentsOf: broken, encoding: .utf8) == "after")
        #expect(try String(contentsOf: good, encoding: .utf8) == "before-good")
    }

    @Test func `a legacy reverting record is treated as already restored`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let file = root.appendingPathComponent("nic.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "dhcp".write(to: file, atomically: true, encoding: .utf8)
        let legacy = """
        {"operationId":"op-legacy","generation":1,"target":"eth0","phase":"reverting",\
        "deadline":\(Date().addingTimeInterval(-5).timeIntervalSince1970),\
        "snapshot":{"files":{\(jsonString(file.path)):"dhcp"},"absentPaths":[],"aclContents":null}}
        """
        let dir = data.appendingPathComponent("host-network/recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.write(to: dir.appendingPathComponent("op-legacy.json"), atomically: true, encoding: .utf8)
        try "static".write(to: file, atomically: true, encoding: .utf8)
        let swept = HostNetworkRecovery.sweepExpired(dataDir: data, now: Date())
        #expect(swept.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "static")
        #expect(throws: BarkVisorError.self) {
            try HostNetworkRecovery.requireConfirmation(
                pending: HostNetworkPendingCommit(
                    target: "eth0",
                    commitDeadline: Date().addingTimeInterval(60),
                    rollbackSeconds: 60,
                    operationId: "op-legacy",
                    generation: 1,
                ),
                requestedOperationId: "op-legacy",
                requestedGeneration: 1,
                authorized: true,
                now: Date(),
                dataDir: data,
            )
        }
    }

    @Test func `an absent path in a snapshot is removed on restore`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let removed = root.appendingPathComponent("removed.txt")
        let kept = root.appendingPathComponent("kept.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try HostNetworkRecovery.begin(
            operationId: "op-old",
            generation: 1,
            target: "br0",
            snapshot: HostNetworkSnapshot(files: [kept.path: "restored"], absentPaths: [removed.path]),
            deadline: Date().addingTimeInterval(-5),
            dataDir: data,
        )
        try "present".write(to: removed, atomically: true, encoding: .utf8)
        #expect(HostNetworkRecovery.sweepExpired(dataDir: data, now: Date()).restored == ["op-old"])
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(try String(contentsOf: kept, encoding: .utf8) == "restored")
    }

    @Test func `recovery records written before restore accounting still decode`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = data.appendingPathComponent("host-network/recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        {"operationId":"op-legacy","generation":1,"target":"eth0","phase":"awaitingConfirmation",\
        "deadline":\(Date().timeIntervalSince1970),"snapshot":{"files":{},"absentPaths":[]}}
        """
        try legacy.write(to: dir.appendingPathComponent("op-legacy.json"), atomically: true, encoding: .utf8)
        let record = HostNetworkRecovery.load(operationId: "op-legacy", dataDir: data)
        #expect(record?.phase == HostNetworkRecoveryPhase.awaitingConfirmation)
        #expect(record?.restoreAttempts == 0)
        #expect(record?.lastRestoreError == nil)
        #expect(record?.restoredAt == nil)
    }

    /// Counts restores across the threads a sweep may run on.
    private final class RestoreCount: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0

        var didRestore: Bool {
            lock.lock()
            defer { lock.unlock() }
            return seen > 0
        }

        func increment() {
            lock.lock()
            seen += 1
            lock.unlock()
        }
    }

    private func jsonString(_ raw: String) -> String {
        guard let data = try? JSONEncoder().encode(raw) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
