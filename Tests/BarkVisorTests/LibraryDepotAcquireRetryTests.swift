import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

final class DepotRetryTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let devices: DeviceRegistry
    private let client: FakeLibraryDepotClient
    private let localHostId = "self-device"

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(pool)
        let library = tmp.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try pool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
        }
        dbPool = pool

        devices = DeviceRegistry(dataDir: tmp)
        try devices.upsert(
            hostId: "depot-device",
            fingerprint: "aa",
            agentHost: "192.168.10.8",
            agentPort: 7_778,
        )
        client = FakeLibraryDepotClient()
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func setDepot() throws {
        try dbPool.write { db in
            try AppSetting(key: LibrarySettings.libraryDepotHostIdKey, value: "depot-device")
                .save(db, onConflict: .replace)
        }
    }

    private func liveAcquire() -> LibraryDepotAcquire {
        let fake = client
        return LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { _ in fake },
            awaitCopy: false,
        )
    }

    private func seedReadyRemote(id: String, source: String) {
        client.images = [
            LibraryDepotImageInfo(
                id: id,
                name: "Cloud",
                imageType: "cloud-image",
                arch: "arm64",
                status: "ready",
                sizeBytes: Int64(client.bytes.count),
                sourceUrl: source,
                sha256: nil,
                slug: "ubuntu",
                filename: "cloud.img",
            ),
        ]
    }

    private func request(_ source: String) -> LibraryDepotFetchRequest {
        LibraryDepotFetchRequest(
            sourceUrl: source,
            name: "Cloud",
            imageType: "cloud-image",
            arch: "arm64",
            expectedChecksum: nil,
        )
    }

    private func waitUntilStatus(id: String, status: String) async throws -> VMImage {
        for _ in 0 ..< 80 {
            if let image = try await dbPool.read({ db in try VMImage.fetchOne(db, key: id) }),
               image.status == status {
                return image
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw BarkVisorError.timeout("depot row did not become \(status)")
    }

    private func fallbackCount() throws -> Int {
        try dbPool.read { db in
            try AuditEntry.order(Column("id")).fetchAll(db)
                .count { $0.action == "library.depot.fallback" }
        }
    }

    @Test func `retry skips depot after copy fail`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-retry.img"
        seedReadyRemote(id: "remote-retry", source: source)
        client.fetchError = BarkVisorError.timeout("copy failed")
        let live = liveAcquire()

        let first = await live.fetchMatching(request(source), db: dbPool)
        let pending = try #require(first)
        #expect(pending.status == "downloading")
        let failed = try await waitUntilStatus(id: pending.id, status: "error")
        #expect(LibraryDepotAcquire.isDepotCopyFailure(failed.error))

        let retry = await live.fetchMatching(request(source), db: dbPool)
        #expect(retry == nil)
        #expect(client.listedURLs == [source])
        #expect(client.fetchedIds == ["remote-retry"])
        let rows = try await dbPool.read { db in try VMImage.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].status == "error")
        #expect(try fallbackCount() == 2)
    }

    @Test func `internet error still uses depot`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-after-internet.img"
        seedReadyRemote(id: "remote-after-internet", source: source)
        let now = "2026-01-01T00:00:00Z"
        try await dbPool.write { db in
            try VMImage(
                id: "img-internet-error", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: nil, sizeBytes: nil, status: "error", error: "HTTP 500 from origin",
                sourceUrl: source, createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let fake = client
        let acquire = LibraryDepotAcquire(
            localHostId: localHostId,
            dataDir: tmpDir,
            devices: devices,
            openClient: { _ in fake },
            awaitCopy: true,
        )
        let image = await acquire.fetchMatching(request(source), db: dbPool)
        let stored = try #require(image)
        #expect(stored.status == "ready")
        #expect(stored.id != "img-internet-error")
        #expect(client.listedURLs == [source])
        #expect(client.fetchedIds == ["remote-after-internet"])
    }

    @Test func `concurrent claims share one row`() async throws {
        try setDepot()
        let source = "https://example.com/cloud-concurrent.img"
        seedReadyRemote(id: "remote-concurrent", source: source)
        let gate = FetchGate()
        client.fetchGate = gate
        let live = liveAcquire()
        let req = request(source)
        let pool = dbPool

        let images = try await withThrowingTaskGroup(of: VMImage?.self) { group in
            group.addTask { await live.fetchMatching(req, db: pool) }
            group.addTask { await live.fetchMatching(req, db: pool) }
            var rows: [VMImage?] = []
            for try await row in group {
                rows.append(row)
            }
            return rows
        }
        let a = try #require(images[0])
        let b = try #require(images[1])
        #expect(a.id == b.id)
        #expect(a.status == "downloading")
        #expect(b.status == "downloading")
        let count = try await dbPool.read { db in try VMImage.fetchCount(db) }
        #expect(count == 1)

        gate.signal()
        gate.signal()
        let ready = try await waitUntilStatus(id: a.id, status: "ready")
        #expect(ready.status == "ready")
        #expect(client.fetchedIds == ["remote-concurrent"])
    }
}
