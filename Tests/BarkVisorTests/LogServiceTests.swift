import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct LogServiceTests {
    private func makeMigratedPool() throws -> (pool: DatabasePool, tmpDir: URL) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)

        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(pool)

        return (pool, tmpDir)
    }

    // MARK: - LogLevel

    @Test func `log level ordering`() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.error < LogLevel.fatal)
    }

    @Test func `log level raw values`() {
        #expect(LogLevel.debug.rawValue == "debug")
        #expect(LogLevel.info.rawValue == "info")
        #expect(LogLevel.warn.rawValue == "warn")
        #expect(LogLevel.error.rawValue == "error")
        #expect(LogLevel.fatal.rawValue == "fatal")
    }

    @Test func `log level from raw value`() {
        #expect(LogLevel(rawValue: "debug") == .debug)
        #expect(LogLevel(rawValue: "info") == .info)
        #expect(LogLevel(rawValue: "warn") == .warn)
        #expect(LogLevel(rawValue: "error") == .error)
        #expect(LogLevel(rawValue: "fatal") == .fatal)
        #expect(LogLevel(rawValue: "verbose") == nil)
    }

    @Test func `log level not greater than self`() {
        for level in [LogLevel.debug, .info, .warn, .error, .fatal] {
            #expect(!(level < level), "\(level) should not be less than itself")
        }
    }

    // MARK: - LogCategory

    @Test func `log category raw values`() {
        #expect(LogCategory.app.rawValue == "app")
        #expect(LogCategory.server.rawValue == "server")
    }

    @Test func `log category all cases`() {
        #expect(LogCategory.allCases.count == 8)
        #expect(LogCategory.allCases.contains(.app))
        #expect(LogCategory.allCases.contains(.server))
    }

    // MARK: - LogEntry Codable

    @Test func `log entry codable`() throws {
        let entry = LogEntry(
            ts: "2025-01-01T00:00:00Z",
            level: .info,
            cat: .app,
            msg: "Test message",
            vm: "vm-1",
            req: "req-1",
            err: nil,
            detail: ["key": "value"],
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)

        #expect(decoded.ts == entry.ts)
        #expect(decoded.level == entry.level)
        #expect(decoded.cat == entry.cat)
        #expect(decoded.msg == entry.msg)
        #expect(decoded.vm == "vm-1")
        #expect(decoded.req == "req-1")
        #expect(decoded.err == nil)
        #expect(decoded.detail?["key"] == "value")
    }

    @Test func `log entry with error`() throws {
        let entry = LogEntry(
            ts: "2025-01-01T00:00:00Z",
            level: .error,
            cat: .server,
            msg: "Failed",
            vm: nil,
            req: nil,
            err: "something broke",
            detail: nil,
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)

        #expect(decoded.err == "something broke")
        #expect(decoded.vm == nil)
        #expect(decoded.detail == nil)
    }

    @Test func `log writes all 8 values to logs table`() async throws {
        let (dbPool, tmpDir) = try makeMigratedPool()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let service = LogService()
        await service.setDatabase(dbPool)

        await service.log(
            .error,
            "placeholder count regression",
            category: .server,
            vm: "vm-1",
            req: "req-1",
            error: "boom",
            detail: ["k": "v"],
        )

        var inserted = false
        for _ in 0 ..< 50 {
            let count = try await dbPool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM logs WHERE msg = ?",
                    arguments: ["placeholder count regression"],
                ) ?? 0
            }
            if count == 1 {
                inserted = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(inserted)

        let fetched = try await dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT level, cat, msg, vm, req, err, detail FROM logs WHERE msg = ?",
                arguments: ["placeholder count regression"],
            )
        }

        #expect((fetched?["level"] as String?) == "error")
        #expect((fetched?["cat"] as String?) == "server")
        #expect((fetched?["msg"] as String?) == "placeholder count regression")
        #expect((fetched?["vm"] as String?) == "vm-1")
        #expect((fetched?["req"] as String?) == "req-1")
        #expect((fetched?["err"] as String?) == "boom")

        let detailJSONString: String? = fetched?["detail"]
        let detailData = try #require(detailJSONString?.data(using: .utf8))
        let detail = try JSONDecoder().decode([String: String].self, from: detailData)
        #expect(detail["k"] == "v")
    }
}
