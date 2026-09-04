import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct PendingVMImageOverlayTests {
    @Test func `pending deploy sets image id and download percent`() async throws {
        let (pool, tmp) = try makeOverlayDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await seedPending(pool: pool, vmID: "vm-1", imageID: "img-1", imageStatus: "downloading")
        let downloader = ImageDownloader(dbPool: { pool })
        await downloader.publish(
            ImageProgressEvent(
                id: "img-1", status: "downloading",
                bytesReceived: 42, totalBytes: 100,
                percent: 42, error: nil,
            ),
        )
        let last = await downloader.lastProgress(imageIDs: ["img-1"])
        let overlays = try await pool.read { db in
            try PendingVMImageOverlay.load(db: db, vmIDs: ["vm-1"], lastProgress: last)
        }
        #expect(overlays["vm-1"]?.pendingImageId == "img-1")
        #expect(overlays["vm-1"]?.downloadPercent == 42)
        #expect(overlays["vm-1"]?.imageStatus == "downloading")
        #expect(
            ImageTransferPercent.current(status: "downloading", lastProgress: last["img-1"]) == 42,
        )
    }

    @Test func `unknown total leaves download percent null`() async throws {
        let (pool, tmp) = try makeOverlayDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await seedPending(pool: pool, vmID: "vm-1", imageID: "img-1", imageStatus: "downloading")
        let overlays = try await pool.read { db in
            try PendingVMImageOverlay.load(db: db, vmIDs: ["vm-1"], lastProgress: [:])
        }
        #expect(overlays["vm-1"]?.pendingImageId == "img-1")
        #expect(overlays["vm-1"]?.downloadPercent == nil)
    }

    @Test func `ready image and deleted pending clear both fields`() async throws {
        let (pool, tmp) = try makeOverlayDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await seedPending(pool: pool, vmID: "vm-1", imageID: "img-1", imageStatus: "ready")
        let readyEvent = ImageProgressEvent(
            id: "img-1", status: "ready",
            bytesReceived: 100, totalBytes: 100,
            percent: 100, error: nil,
        )
        let whilePending = try await pool.read { db in
            try PendingVMImageOverlay.load(
                db: db, vmIDs: ["vm-1"], lastProgress: ["img-1": readyEvent],
            )
        }
        #expect(whilePending["vm-1"]?.pendingImageId == "img-1")
        #expect(whilePending["vm-1"]?.downloadPercent == nil)
        _ = try await pool.write { db in
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == "vm-1").deleteAll(db)
        }
        let gone = try await pool.read { db in
            try PendingVMImageOverlay.load(db: db, vmIDs: ["vm-1"], lastProgress: [:])
        }
        #expect(gone["vm-1"] == nil)
    }

    @Test func `progress ticker yields pending fields then clears them`() async throws {
        let (pool, tmp) = try makeOverlayDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await seedPending(pool: pool, vmID: "vm-1", imageID: "img-1", imageStatus: "downloading")
        let downloader = ImageDownloader(dbPool: { pool })
        await downloader.publish(
            ImageProgressEvent(
                id: "img-1", status: "downloading",
                bytesReceived: 10, totalBytes: 100,
                percent: 10, error: nil,
            ),
        )
        let stream = VMStateStreamService()
        let events = await stream.stateStream(vmID: "vm-1")
        var iterator = events.makeAsyncIterator()
        let ticker = PendingVMProgressTicker()
        await ticker.tick(db: pool, downloader: downloader, stream: stream)
        let first = await iterator.next()
        #expect(first?.pendingImageId == "img-1")
        #expect(first?.downloadPercent == 10)
        #expect(first?.state == "provisioning")
        _ = try await pool.write { db in
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == "vm-1").deleteAll(db)
        }
        await ticker.tick(db: pool, downloader: downloader, stream: stream)
        let second = await iterator.next()
        #expect(second?.pendingImageId == nil)
        #expect(second?.downloadPercent == nil)
    }

    @Test func `failed tick clears last sent so the next tick resends`() async throws {
        let (pool, tmp) = try makeOverlayDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let badTmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: badTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: badTmp) }
        try await seedPending(pool: pool, vmID: "vm-1", imageID: "img-1", imageStatus: "downloading")
        let downloader = ImageDownloader(dbPool: { pool })
        await downloader.publish(
            ImageProgressEvent(
                id: "img-1", status: "downloading",
                bytesReceived: 10, totalBytes: 100,
                percent: 10, error: nil,
            ),
        )
        let stream = VMStateStreamService()
        let events = await stream.stateStream(vmID: "vm-1")
        var iterator = events.makeAsyncIterator()
        let ticker = PendingVMProgressTicker()
        await ticker.tick(db: pool, downloader: downloader, stream: stream)
        let first = await iterator.next()
        #expect(first?.pendingImageId == "img-1")
        let badPool = try DatabasePool(path: badTmp.appendingPathComponent("bad.sqlite").path)
        await ticker.tick(db: badPool, downloader: downloader, stream: stream)
        await ticker.tick(db: pool, downloader: downloader, stream: stream)
        let resent = await nextEventOrTimeout(EventIteratorBox(iterator))
        #expect(resent?.pendingImageId == "img-1")
        #expect(resent?.downloadPercent == 10)
    }
}

private final class EventIteratorBox: @unchecked Sendable {
    var iterator: AsyncStream<VMStateEvent>.Iterator
    init(_ iterator: AsyncStream<VMStateEvent>.Iterator) {
        self.iterator = iterator
    }
}

private func nextEventOrTimeout(
    _ box: EventIteratorBox,
) async -> VMStateEvent? {
    await withTaskGroup(of: VMStateEvent?.self) { group in
        group.addTask { await box.iterator.next() }
        group.addTask {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func seedPending(
    pool: DatabasePool,
    vmID: String,
    imageID: String,
    imageStatus: String,
) async throws {
    let now = "2026-01-01T00:00:00Z"
    try await pool.write { db in
        try Disk(
            id: "disk-\(vmID)",
            name: "boot",
            path: "/tmp/\(vmID).qcow2",
            sizeBytes: 1,
            format: "qcow2",
            vmId: vmID,
            autoCreated: false,
            status: "creating",
            createdAt: now,
        ).insert(db)
        try VM(
            id: vmID,
            name: vmID,
            vmType: "linux-arm64",
            state: "provisioning",
            cpuCount: 1,
            memoryMb: 512,
            bootDiskId: "disk-\(vmID)",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: now,
            updatedAt: now,
        ).insert(db)
        try VMImage(
            id: imageID,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            path: nil,
            sizeBytes: nil,
            status: imageStatus,
            error: nil,
            sourceUrl: "https://example.com/img.qcow2",
            sha256: nil,
            createdAt: now,
            updatedAt: now,
        ).insert(db)
        try PendingDeploy(
            vmId: vmID,
            imageId: imageID,
            payload: "{}",
            createdAt: now,
        ).insert(db)
    }
}

private func makeOverlayDB() throws -> (DatabasePool, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    return (pool, tmp)
}
