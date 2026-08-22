import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// PAS-90 leftover polish: SQLite is process authority, Home inventory is an
/// index, reconnect must not thrash Workloads, no live migration, no SIGKILL
/// unless the user asked for Force Stop.
@Suite("Independent execution (PAS-90)")
struct IndependentExecutionTests {
    @Test func `hard kill only when force stop is explicit`() {
        #expect(!IndependentExecution.allowsHardKill(force: false, method: "acpi"))
        #expect(!IndependentExecution.allowsHardKill(force: false, method: "guest-agent"))
        #expect(IndependentExecution.allowsHardKill(force: true, method: "acpi"))
        #expect(IndependentExecution.allowsHardKill(force: false, method: "force"))
        #expect(IndependentExecution.allowsHardKill(force: true, method: "force"))
    }

    @Test func `reconnect adopts a live QEMU even without sockets`() {
        #expect(
            IndependentExecution.reconnectAction(
                alreadyRegistered: false,
                processAlive: true,
                isQEMU: true,
                hasDBRecord: true,
            ) == .adopt,
        )
    }

    @Test func `reconnect does not re-attach an already registered Workload`() {
        #expect(
            IndependentExecution.reconnectAction(
                alreadyRegistered: true,
                processAlive: true,
                isQEMU: true,
                hasDBRecord: true,
            ) == .skipAlreadyRegistered,
        )
    }

    @Test func `reconnect cleans stale pid files without killing a reused pid`() {
        #expect(
            IndependentExecution.reconnectAction(
                alreadyRegistered: false,
                processAlive: false,
                isQEMU: false,
                hasDBRecord: true,
            ) == .cleanupDead,
        )
        #expect(
            IndependentExecution.reconnectAction(
                alreadyRegistered: false,
                processAlive: true,
                isQEMU: false,
                hasDBRecord: true,
            ) == .cleanupPidReuse,
        )
        #expect(
            IndependentExecution.reconnectAction(
                alreadyRegistered: false,
                processAlive: true,
                isQEMU: true,
                hasDBRecord: false,
            ) == .cleanupOrphanNoRecord,
        )
    }

    @Test func `published contract has no live migration routes`() {
        let paths = APIContract.routes.map(\.path)
        #expect(!IndependentExecution.contractAllowsLiveMigration(paths: paths))
        #expect(
            IndependentExecution.contractAllowsLiveMigration(
                paths: ["/api/vms/{id}/migrate"],
            ),
        )
        #expect(
            IndependentExecution.contractAllowsLiveMigration(
                paths: ["/api/workloads/{id}/live-migration"],
            ),
        )
        #expect(
            !IndependentExecution.contractAllowsLiveMigration(
                paths: ["/api/images/{id}", "/api/vms/{id}/start"],
            ),
        )
    }

    @Test func `reconnect registration does not replace a live handle for the same pid`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let manager = VMManager(dbPool: pool)

        let first = RunningVM(
            process: nil,
            pid: 11,
            serialSocketPath: "/tmp/s",
            vncSocketPath: "/tmp/v",
            qmpSocketPath: "/tmp/q",
            qmpEventSocketPath: "/tmp/e",
            swtpmProcess: nil,
            reconnected: false,
            swtpmPid: 22,
        )
        await manager.registerReconnectedVM(vmID: "vm-1", running: first)
        let second = RunningVM(
            process: nil,
            pid: 11,
            serialSocketPath: "/tmp/s2",
            vncSocketPath: "/tmp/v2",
            qmpSocketPath: "/tmp/q2",
            qmpEventSocketPath: "/tmp/e2",
            swtpmProcess: nil,
            reconnected: true,
            swtpmPid: 22,
        )
        await manager.registerReconnectedVM(vmID: "vm-1", running: second)
        let kept = await manager.runningVMs["vm-1"]
        #expect(kept?.reconnected == false)
        #expect(kept?.qmpSocketPath == "/tmp/q")
    }
}
