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
        #expect(swept.deferred == ["op-old"])
        #expect(HostNetworkRecovery.load(operationId: "op-old", dataDir: data)?.phase
            == HostNetworkRecoveryPhase.mutating)
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
        _ = try HostNetworkRecovery.begin(
            operationId: "op-live",
            generation: 2,
            target: "eth0",
            snapshot: HostNetworkSnapshot(),
            deadline: Date().addingTimeInterval(60),
            dataDir: data,
        )
        #expect(HostNetworkRecovery.list(dataDir: data).count == 4)
        #expect(HostNetworkRecovery.prune(dataDir: data, now: Date()).sorted()
            == ["op-legacy", "op-restored", "op-superseded"])
        #expect(HostNetworkRecovery.list(dataDir: data).map(\.operationId) == ["op-live"])
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

    private func jsonString(_ raw: String) -> String {
        guard let data = try? JSONEncoder().encode(raw) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
