import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite("Per-Device Ollama upstream keys")
struct OllamaSettingsTests {
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

    @Test func `legacy global key seeds self and stays as fallback`() throws {
        try dbPool.write { db in
            try AppSetting(key: OllamaSettings.apiKeyKey, value: "global-secret-key")
                .save(db, onConflict: .replace)
        }
        let snap = try dbPool.write { db in
            try OllamaSettings.list(knownHostIds: [], selfHostId: "home", from: db)
        }
        let selfRow = try #require(snap.host("home"))
        #expect(selfRow.hasApiKey)
        let loaded = try dbPool.read { db in
            try OllamaSettings.load(hostId: "home", from: db)
        }
        #expect(loaded.apiKey == "global-secret-key")
        let fallback = try dbPool.read { db in
            try OllamaSettings.load(hostId: "desk", from: db)
        }
        #expect(fallback.apiKey == "global-secret-key")
        let global = try dbPool.read { db in
            try AppSetting.fetchOne(db, key: OllamaSettings.apiKeyKey)?.value
        }
        #expect(global == "global-secret-key")
    }

    @Test func `read masks the key and never returns plaintext`() throws {
        let snap = try dbPool.write { db in
            try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: "sk-live-abcd1234",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
        }
        let desk = try #require(snap.host("desk"))
        #expect(desk.hasApiKey)
        #expect(desk.apiKeyMasked == "••••")
        #expect(!(desk.apiKeyMasked?.contains("1234") ?? false))
        let data = try JSONEncoder().encode(snap)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("sk-live-abcd1234"))
        #expect(!json.contains("\"apiKey\""))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hosts = object?["hosts"] as? [[String: Any]]
        #expect(hosts?.contains { $0["apiKey"] != nil } != true)
    }

    @Test func `round-trip keeps per-Device keys and clearing does not fall back`() throws {
        _ = try dbPool.write { db in
            try AppSetting(key: OllamaSettings.apiKeyKey, value: "global-secret-key")
                .save(db, onConflict: .replace)
            try OllamaSettings.save(
                hostId: "desk",
                endpoint: "http://127.0.0.1:11434",
                apiKey: "desk-secret-key",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
            try OllamaSettings.save(
                hostId: "laptop",
                endpoint: nil,
                apiKey: "laptop-secret-key",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
        }
        let desk = try dbPool.read { db in try OllamaSettings.load(hostId: "desk", from: db) }
        let laptop = try dbPool.read { db in try OllamaSettings.load(hostId: "laptop", from: db) }
        #expect(desk.apiKey == "desk-secret-key")
        #expect(laptop.apiKey == "laptop-secret-key")
        #expect(desk.endpoint.absoluteString.contains("11434"))
        let client = try dbPool.read { db in
            try OllamaSettings.client(hostId: "desk", from: db)
        }
        #expect(client.apiKey == "desk-secret-key")
        _ = try dbPool.write { db in
            try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: "",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
        }
        let cleared = try dbPool.read { db in try OllamaSettings.load(hostId: "desk", from: db) }
        #expect(cleared.apiKey == nil)
    }

    @Test func `omit apiKey leaves the stored key`() throws {
        _ = try dbPool.write { db in
            try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: "keep-me-secret",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
            try OllamaSettings.save(
                hostId: "desk",
                endpoint: "http://127.0.0.1:11434",
                apiKey: nil,
                updateApiKey: false,
                selfHostId: "home",
                db: db,
            )
        }
        let loaded = try dbPool.read { db in try OllamaSettings.load(hostId: "desk", from: db) }
        #expect(loaded.apiKey == "keep-me-secret")
    }

    @Test func `migration seeds self from the legacy global row`() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try M001_CreateSchema.migrate(db)
            try AppSetting(key: OllamaSettings.endpointKey, value: "http://127.0.0.1:11434").insert(db)
            try AppSetting(key: OllamaSettings.apiKeyKey, value: "legacy-secret").insert(db)
            try M014_OllamaPerHostSettings.migrate(db)
        }
        try queue.read { db in
            let loaded = try OllamaSettings.load(hostId: Config.hostId, from: db)
            #expect(loaded.apiKey == "legacy-secret")
            #expect(try OllamaSettings.loadGlobal(from: db).apiKey == "legacy-secret")
        }
    }

    @Test func `router pick then client uses that Device key`() throws {
        try dbPool.write { db in
            _ = try OllamaSettings.save(
                hostId: "desk",
                endpoint: nil,
                apiKey: "desk-key",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
            _ = try OllamaSettings.save(
                hostId: "idle",
                endpoint: nil,
                apiKey: "idle-key",
                updateApiKey: true,
                selfHostId: "home",
                db: db,
            )
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let probed = iso8601.string(from: now)
        let desk = OllamaModelLocation(
            hostId: "desk",
            displayName: "desk",
            running: true,
            reachable: true,
            probedAt: probed,
            memoryTotalMB: 8_192,
            memoryUsedMB: 1_024,
            cpuLoadPercent: 4,
        )
        let picked = OllamaRouter.pick(model: "llama3", locations: [desk], now: now)
        #expect(picked?.hostId == "desk")
        try dbPool.read { db in
            let client = try OllamaSettings.client(hostId: picked?.hostId ?? "", from: db)
            #expect(client.apiKey == "desk-key")
        }
    }
}
