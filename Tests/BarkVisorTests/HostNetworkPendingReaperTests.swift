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

    private func tempPool() throws -> DatabasePool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-net-reaper-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: path.path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }
}
