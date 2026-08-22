import Foundation
import GRDB
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home library controller (PAS-39)")
struct HomeLibraryControllerTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "home-lib-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pool(in dir: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let library = dir.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try pool.write { db in
            try AppSetting(key: LibrarySettings.imageDirectoryKey, value: library.path)
                .save(db, onConflict: .replace)
        }
        return pool
    }

    private func seedLocalImage(db: DatabasePool, id: String = "local-1") async throws {
        let now = "2026-01-01T00:00:00Z"
        try await db.write { db in
            try VMImage(
                id: id, name: "ubuntu.iso", imageType: "iso", arch: "arm64",
                path: "/data/images/\(id).iso", sizeBytes: 1_024,
                status: "ready", error: nil, sourceUrl: nil, sha256: "abc",
                createdAt: now, updatedAt: now,
            ).insert(db)
        }
    }

    @Test func `catalog includes local metadata and skips a down member`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try pool(in: dir)
        try await seedLocalImage(db: db)
        let devices = DeviceRegistry(dataDir: dir)
        try devices.upsert(
            hostId: "studio", fingerprint: "bb",
            agentHost: "192.168.10.9", agentPort: 7_778,
        )
        let client = RecordingLibraryProxy()
        client.fail(host: "192.168.10.9", port: 7_778, path: "/api/images", error: HomeDeviceProxyError.unreachable("down"))
        let controller = HomeLibraryController(
            dataDir: dir, hostId: "desk", devices: devices, mtlsClient: client,
        )
        let list = await controller.catalog(db: db, bearer: "token")
        #expect(list.images.count == 1)
        #expect(list.images[0].libraryKey == "sha256:abc")
        #expect(list.images[0].copies.map(\.hostId) == ["desk"])
        let encoded = try JSONEncoder().encode(list.images[0])
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("/data/images"))
    }

    @Test func `catalog merges a member listing by checksum`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try pool(in: dir)
        try await seedLocalImage(db: db)
        let devices = DeviceRegistry(dataDir: dir)
        try devices.upsert(
            hostId: "studio", fingerprint: "bb",
            agentHost: "192.168.10.9", agentPort: 7_778,
        )
        let peer = HomeLibraryDeviceImage(
            id: "peer-1", name: "ubuntu.iso", imageType: "iso", arch: "arm64",
            status: "ready", sizeBytes: 1_024, sourceUrl: nil, error: nil, sha256: "abc",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
        )
        let client = RecordingLibraryProxy()
        try client.respond(
            host: "192.168.10.9", port: 7_778, path: "/api/images",
            status: 200, body: JSONEncoder().encode([peer]),
        )
        let controller = HomeLibraryController(
            dataDir: dir, hostId: "desk", devices: devices, mtlsClient: client,
        )
        let list = await controller.catalog(db: db, bearer: nil)
        #expect(list.images.count == 1)
        #expect(Set(list.images[0].sourceHostIds) == ["desk", "studio"])
    }

    @Test func `prefetch of a copy this Device already has is a no-op`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try pool(in: dir)
        try await seedLocalImage(db: db)
        let controller = HomeLibraryController(dataDir: dir, hostId: "desk")
        let result = try await controller.prefetch(
            HomeLibraryPrefetchRequest(libraryKey: "sha256:abc", hostId: "desk"),
            db: db,
            bearer: nil,
        )
        #expect(result.image.id == "local-1")
        #expect(result.image.status == "ready")
    }

    @Test func `prefetch without a source copy conflicts`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try pool(in: dir)
        let now = "2026-01-01T00:00:00Z"
        try await db.write { db in
            try VMImage(
                id: "local-1", name: "ubuntu.iso", imageType: "iso", arch: "arm64",
                path: nil, sizeBytes: nil,
                status: "downloading", error: nil, sourceUrl: nil, sha256: "abc",
                createdAt: now, updatedAt: now,
            ).insert(db)
        }
        let devices = DeviceRegistry(dataDir: dir)
        try devices.upsert(
            hostId: "studio", fingerprint: "bb",
            agentHost: "192.168.10.9", agentPort: 7_778,
        )
        let client = RecordingLibraryProxy()
        let controller = HomeLibraryController(
            dataDir: dir, hostId: "desk", devices: devices, mtlsClient: client,
        )
        do {
            _ = try await controller.prefetch(
                HomeLibraryPrefetchRequest(libraryKey: "sha256:abc", hostId: "studio"),
                db: db,
                bearer: nil,
            )
            Issue.record("expected conflict")
        } catch let error as BarkVisorError {
            guard case .conflict = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }
}

private final class RecordingLibraryProxy: HomeDeviceProxyClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Result<HomeDeviceProxyResponse, Error>] = [:]

    func respond(host: String, port: Int, path: String, status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(host):\(port)\(path)"] = .success(
            HomeDeviceProxyResponse(status: status, body: body),
        )
    }

    func fail(host: String, port: Int, path: String, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(host):\(port)\(path)"] = .failure(error)
    }

    func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        switch lookup(request) {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        case nil:
            return HomeDeviceProxyResponse(status: 404, body: Data())
        }
    }

    private func lookup(_ request: HomeDeviceProxyRequest) -> Result<HomeDeviceProxyResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(request.url.host ?? ""):\(request.url.port ?? 0)\(request.url.path)"
        return responses[key]
    }
}
