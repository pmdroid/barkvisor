import Foundation
import Testing
@testable import BarkVisorCore

@Suite struct LogServiceTests {
    // MARK: - LogLevel

    @Test func logLevelOrdering() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.error < LogLevel.fatal)
    }

    @Test func logLevelRawValues() {
        #expect(LogLevel.debug.rawValue == "debug")
        #expect(LogLevel.info.rawValue == "info")
        #expect(LogLevel.warn.rawValue == "warn")
        #expect(LogLevel.error.rawValue == "error")
        #expect(LogLevel.fatal.rawValue == "fatal")
    }

    @Test func logLevelFromRawValue() {
        #expect(LogLevel(rawValue: "debug") == .debug)
        #expect(LogLevel(rawValue: "info") == .info)
        #expect(LogLevel(rawValue: "warn") == .warn)
        #expect(LogLevel(rawValue: "error") == .error)
        #expect(LogLevel(rawValue: "fatal") == .fatal)
        #expect(LogLevel(rawValue: "verbose") == nil)
    }

    @Test func logLevelNotGreaterThanSelf() {
        for level in [LogLevel.debug, .info, .warn, .error, .fatal] {
            #expect(!(level < level), "\(level) should not be less than itself")
        }
    }

    // MARK: - LogCategory

    @Test func logCategoryRawValues() {
        #expect(LogCategory.app.rawValue == "app")
        #expect(LogCategory.server.rawValue == "server")
    }

    @Test func logCategoryAllCases() {
        #expect(LogCategory.allCases.count == 8)
        #expect(LogCategory.allCases.contains(.app))
        #expect(LogCategory.allCases.contains(.server))
    }

    // MARK: - LogEntry Codable

    @Test func logEntryCodable() throws {
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

    @Test func logEntryWithError() throws {
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
}
