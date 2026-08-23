import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct WorkloadAutostartTests {
    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue)
        return queue
    }

    private func insertVM(
        _ db: Database,
        id: String,
        startOnBoot: Bool,
        state: String = "stopped",
        workloadClass: String = "house",
    ) throws {
        try Disk(
            id: "disk-\(id)",
            name: "boot",
            path: "/data/\(id).qcow2",
            sizeBytes: 1_024,
            format: "qcow2",
            vmId: id,
            autoCreated: false,
            status: "ready",
            createdAt: "2026-01-01T00:00:00Z",
        ).insert(db)
        try VM(
            id: id,
            name: id,
            vmType: "linux-arm64",
            state: state,
            cpuCount: 1,
            memoryMb: 512,
            bootDiskId: "disk-\(id)",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: "cd",
            displayResolution: "1280x800",
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            workloadClass: workloadClass,
            startOnBoot: startOnBoot,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        ).insert(db)
    }

    @Test func `new rows default startOnBoot off`() throws {
        let queue = try migratedQueue()
        try queue.write { db in
            try insertVM(db, id: "house-1", startOnBoot: false)
        }
        let fetched = try queue.read { db in try VM.fetchOne(db, key: "house-1") }
        #expect(fetched?.startOnBoot == false)
        #expect(fetched?.workloadClass == "house")
    }

    @Test func `startOnBoot round trip`() throws {
        let queue = try migratedQueue()
        try queue.write { db in
            try insertVM(db, id: "agent-1", startOnBoot: true, workloadClass: "agent")
        }
        let fetched = try queue.read { db in try VM.fetchOne(db, key: "agent-1") }
        #expect(fetched?.startOnBoot == true)
        #expect(fetched?.workloadClass == "agent")
    }

    @Test func `new Device boot starts opted-in stopped Workloads only`() throws {
        let queue = try migratedQueue()
        try queue.write { db in
            try insertVM(db, id: "off-house", startOnBoot: false, workloadClass: "house")
            try insertVM(db, id: "on-house", startOnBoot: true, workloadClass: "house")
            try insertVM(db, id: "on-agent", startOnBoot: true, workloadClass: "agent")
            try insertVM(db, id: "on-running", startOnBoot: true, state: "running")
            try insertVM(db, id: "on-error", startOnBoot: true, state: "error")
        }
        let plan = try queue.read { db in
            try WorkloadAutostart.plan(
                db: db,
                bootID: "boot-2",
                alreadyRunningIDs: ["on-running"],
            )
        }
        #expect(plan.isDeviceBoot)
        #expect(Set(plan.vmIDs) == ["on-house", "on-agent", "on-error"])
        #expect(!plan.vmIDs.contains("off-house"))
        #expect(!plan.vmIDs.contains("on-running"))
    }

    @Test func `same boot does not start stopped House appliances`() throws {
        let queue = try migratedQueue()
        try queue.write { db in
            try insertVM(db, id: "haos", startOnBoot: true, workloadClass: "house")
            try WorkloadAutostart.recordBootID("boot-1", db: db)
        }
        let plan = try queue.read { db in
            try WorkloadAutostart.plan(db: db, bootID: "boot-1", alreadyRunningIDs: [])
        }
        #expect(!plan.isDeviceBoot)
        #expect(plan.vmIDs.isEmpty)
    }

    @Test func `updateVM persists startOnBoot without pendingChanges`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try await pool.write { db in
            try insertVM(db, id: "vm-boot", startOnBoot: false, state: "running")
        }
        let updated = try await VMLifecycleService.updateVM(
            id: "vm-boot",
            params: UpdateVMParams(startOnBoot: true),
            db: pool,
        )
        #expect(updated.startOnBoot)
        #expect(!updated.pendingChanges)
        #expect(updated.specGeneration == 1)
    }

    @Test func `device boot id is available on this host`() {
        let id = DeviceBootIdentity.current()
        #expect(id != nil)
        #expect(!(id ?? "").isEmpty)
    }

    @Test func `autostart uses VMManager start so Agent cage stays on the launch path`() {
        // WorkloadAutostart.startEligible calls VMManager.start, which goes through
        // QEMUBuilder → AgentNetworkCage.wrapLaunch. There is no bypass launch.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BarkVisorCore/Services/WorkloadAutostart.swift")
        let text = try? String(contentsOf: source, encoding: .utf8)
        #expect(text?.contains("vmManager.start(vmID:") == true)
        #expect(text?.contains("QEMULaunchConfig") != true)
    }
}
