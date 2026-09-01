import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct ISOAttachTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    @Test func `attach ISO appends a ready ISO and detach removes it`() async throws {
        try await seed(vmID: "vm-1", images: [
            ("iso-ready", "iso", "ready"),
        ])
        let manager = VMManager(dbPool: dbPool)
        try await manager.attachISO(vmID: "vm-1", isoId: "iso-ready")
        var vm = try await loadVM("vm-1")
        #expect(vm.decodedISOIds == ["iso-ready"])
        try await manager.detachISO(vmID: "vm-1", isoId: "iso-ready")
        vm = try await loadVM("vm-1")
        #expect(vm.decodedISOIds.isEmpty)
    }

    @Test func `attach ISO rejects missing cloud and in-flight images`() async throws {
        try await seed(vmID: "vm-2", images: [
            ("img-cloud", "cloud-image", "ready"),
            ("iso-dl", "iso", "downloading"),
        ])
        let manager = VMManager(dbPool: dbPool)
        await #expect(throws: BarkVisorError.self) {
            try await manager.attachISO(vmID: "vm-2", isoId: "missing")
        }
        await #expect(throws: BarkVisorError.self) {
            try await manager.attachISO(vmID: "vm-2", isoId: "img-cloud")
        }
        await #expect(throws: BarkVisorError.self) {
            try await manager.attachISO(vmID: "vm-2", isoId: "iso-dl")
        }
        let vm = try await loadVM("vm-2")
        #expect(vm.decodedISOIds.isEmpty)
    }

    @Test func `attach ISO is a no-op when already attached`() async throws {
        try await seed(vmID: "vm-3", images: [
            ("iso-ready", "iso", "ready"),
        ], isoIds: #"["iso-ready"]"#)
        let manager = VMManager(dbPool: dbPool)
        try await manager.attachISO(vmID: "vm-3", isoId: "iso-ready")
        let vm = try await loadVM("vm-3")
        #expect(vm.decodedISOIds == ["iso-ready"])
    }

    private func loadVM(_ id: String) async throws -> VM {
        try #require(try await dbPool.read { db in try VM.fetchOne(db, key: id) })
    }

    private func seed(
        vmID: String,
        images: [(String, String, String)],
        isoIds: String? = nil,
    ) async throws {
        let now = "2026-01-01T00:00:00Z"
        let diskID = "disk-\(vmID)"
        try await dbPool.write { db in
            try Disk(
                id: diskID,
                name: "boot",
                path: tmpDir.appendingPathComponent("\(diskID).qcow2").path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: vmID,
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            for (id, imageType, status) in images {
                try VMImage(
                    id: id,
                    name: id,
                    imageType: imageType,
                    arch: "arm64",
                    path: tmpDir.appendingPathComponent("\(id).iso").path,
                    sizeBytes: 1_024,
                    status: status,
                    error: nil,
                    sourceUrl: nil,
                    createdAt: now,
                    updatedAt: now,
                ).insert(db)
            }
            try VM(
                id: vmID,
                name: "iso-vm",
                vmType: "linux-arm64",
                state: "stopped",
                cpuCount: 1,
                memoryMb: 512,
                bootDiskId: diskID,
                isoIds: isoIds,
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
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
    }
}
