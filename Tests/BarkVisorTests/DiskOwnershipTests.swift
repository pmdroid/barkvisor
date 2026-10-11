import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class DiskOwnershipTests {
    private let db: DatabasePool
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try DatabasePool(path: root.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(db)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func `additional attachment blocks disk deletion`() async throws {
        try seed(id: "boot-a", owner: "vm-a")
        let file = try seed(id: "data", owner: nil)
        try insertVM(id: "vm-a", boot: "boot-a", extras: ["data"])
        let cache = DiskInfoCache(dbPool: db)
        await #expect(throws: BarkVisorError.self) {
            try await DiskService.deleteDisk(id: "data", diskInfoCache: cache, db: db)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        let row = try await db.read { try Disk.fetchOne($0, key: "data") }
        #expect(row != nil)
    }

    @Test func `deleting another VM does not clear boot owner or cascade`() async throws {
        let file = try seed(id: "boot-a", owner: "vm-a")
        try insertVM(id: "vm-a", boot: "boot-a", extras: [])
        try insertVM(id: "vm-b", boot: nil, extras: ["boot-a"])
        let victim = try await db.read { try #require(try VM.fetchOne($0, key: "vm-b")) }
        try await VMLifecycleService.removeDeleteDisks(vm: victim, keepDisk: true, db: db)
        let owner = try await db.read { try Disk.fetchOne($0, key: "boot-a")?.vmId }
        #expect(owner == "vm-a")
        let cache = DiskInfoCache(dbPool: db)
        await #expect(throws: BarkVisorError.self) {
            try await DiskService.deleteDisk(id: "boot-a", diskInfoCache: cache, db: db)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        let survivor = try await db.read { try VM.fetchOne($0, key: "vm-a") }
        #expect(survivor != nil)
    }

    @Test func `owned additional disk detaches only for its owner`() async throws {
        try seed(id: "data", owner: "vm-b")
        try insertVM(id: "vm-b", boot: nil, extras: ["data"])
        let owner = try await db.read { try #require(try VM.fetchOne($0, key: "vm-b")) }
        try await VMLifecycleService.removeDeleteDisks(vm: owner, keepDisk: true, db: db)
        let detached = try await db.read { try Disk.fetchOne($0, key: "data")?.vmId }
        #expect(detached == nil)
    }

    @Test func `online extra disk resize uses the referencing running VM`() async throws {
        try seed(id: "data", owner: nil, bytes: 1_073_741_824)
        try insertVM(id: "vm-a", boot: nil, extras: ["data"], state: "running")
        let qmp = RecordingQMP()
        let request = DiskResizeRequest(
            id: "data", sizeGB: 2, vmState: StaticVMState(running: ["vm-a"]),
            qmpDiskService: QMPDiskService(vmManager: VMManager(dbPool: db), dbPool: db, resizer: qmp),
            diskInfoCache: DiskInfoCache(dbPool: db),
        )
        _ = try await DiskService.resizeDisk(request, db: db)
        #expect(qmp.calls.count == 1)
        #expect(qmp.calls.first?.0 == "vm-a")
        #expect(qmp.calls.first?.1 == "extra0")
        #expect(qmp.calls.first?.2 == 2_147_483_648)
    }

    private func seed(id: String, owner: String?, bytes: Int64 = 4) throws -> URL {
        let file = root.appendingPathComponent("\(id).qcow2")
        try Data("qcow".utf8).write(to: file)
        try db.write { db in
            try Disk(
                id: id, name: id, path: file.path, sizeBytes: bytes, format: "qcow2",
                vmId: owner, autoCreated: false, status: "ready", createdAt: "2026-01-01T00:00:00Z",
            ).insert(db)
        }
        return file
    }

    private func insertVM(id: String, boot: String?, extras: [String], state: String = "stopped") throws {
        try db.write { db in
            var vm = VM(
                id: id, name: id, vmType: "linux", state: state, cpuCount: 1, memoryMb: 512,
                bootDiskId: boot, networkId: nil, cloudInitPath: nil, description: nil,
                bootOrder: nil, displayResolution: nil, additionalDiskIds: nil, uefi: false,
                tpmEnabled: false, macAddress: nil, sharedPaths: nil, portForwards: nil,
                autoCreated: false, pendingChanges: false, createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
            )
            vm.setAdditionalDiskIds(extras.isEmpty ? nil : extras)
            try vm.insert(db)
        }
    }
}

private struct StaticVMState: VMStateQuerying {
    let running: Set<String>
    func isRunning(_ vmID: String) async -> Bool {
        running.contains(vmID)
    }
    func isActiveOrStarting(_ vmID: String) async -> Bool {
        running.contains(vmID)
    }
    func allRunningVMs() async -> [String: RunningVM] {
        Dictionary(uniqueKeysWithValues: running.map { id in
            (id, RunningVM(
                process: nil, pid: 1, serialSocketPath: "", vncSocketPath: "",
                qmpSocketPath: "", qmpEventSocketPath: "", swtpmProcess: nil,
                reconnected: true, workloadID: id,
            ))
        })
    }
    func vncSocketPath(for vmID: String) async -> String? {
        nil
    }
    func serialSocketPath(for vmID: String) async -> String? {
        nil
    }
    func qmpSocketPath(for vmID: String) async -> String? {
        nil
    }
}

private final class RecordingQMP: QMPDiskResizing, @unchecked Sendable {
    var calls: [(String, String, Int64)] = []
    func resize(vmID: String, disk: Disk, device: String, sizeBytes: Int64) async throws {
        calls.append((vmID, device, sizeBytes))
    }
}
