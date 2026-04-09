import XCTest
@testable import BarkVisorCore

final class LogServiceTests: XCTestCase {
    // MARK: - LogLevel

    func testLogLevelOrdering() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warn)
        XCTAssertTrue(LogLevel.warn < LogLevel.error)
        XCTAssertTrue(LogLevel.error < LogLevel.fatal)
    }

    func testLogLevelRawValues() {
        XCTAssertEqual(LogLevel.debug.rawValue, "debug")
        XCTAssertEqual(LogLevel.info.rawValue, "info")
        XCTAssertEqual(LogLevel.warn.rawValue, "warn")
        XCTAssertEqual(LogLevel.error.rawValue, "error")
        XCTAssertEqual(LogLevel.fatal.rawValue, "fatal")
    }

    func testLogLevelFromRawValue() {
        XCTAssertEqual(LogLevel(rawValue: "debug"), .debug)
        XCTAssertEqual(LogLevel(rawValue: "info"), .info)
        XCTAssertEqual(LogLevel(rawValue: "warn"), .warn)
        XCTAssertEqual(LogLevel(rawValue: "error"), .error)
        XCTAssertEqual(LogLevel(rawValue: "fatal"), .fatal)
        XCTAssertNil(LogLevel(rawValue: "verbose"))
    }

    func testLogLevelNotGreaterThanSelf() {
        for level in [LogLevel.debug, .info, .warn, .error, .fatal] {
            XCTAssertFalse(level < level, "\(level) should not be less than itself")
        }
    }

    // MARK: - LogCategory

    func testLogCategoryRawValues() {
        XCTAssertEqual(LogCategory.app.rawValue, "app")
        XCTAssertEqual(LogCategory.server.rawValue, "server")
    }

    func testLogCategoryAllCases() {
        XCTAssertEqual(LogCategory.allCases.count, 8)
        XCTAssertTrue(LogCategory.allCases.contains(.app))
        XCTAssertTrue(LogCategory.allCases.contains(.server))
    }

    // MARK: - LogEntry Codable

    func testLogEntryCodable() throws {
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

        XCTAssertEqual(decoded.ts, entry.ts)
        XCTAssertEqual(decoded.level, entry.level)
        XCTAssertEqual(decoded.cat, entry.cat)
        XCTAssertEqual(decoded.msg, entry.msg)
        XCTAssertEqual(decoded.vm, "vm-1")
        XCTAssertEqual(decoded.req, "req-1")
        XCTAssertNil(decoded.err)
        XCTAssertEqual(decoded.detail?["key"], "value")
    }

    func testLogEntryWithError() throws {
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

        XCTAssertEqual(decoded.err, "something broke")
        XCTAssertNil(decoded.vm)
        XCTAssertNil(decoded.detail)
    }
}
