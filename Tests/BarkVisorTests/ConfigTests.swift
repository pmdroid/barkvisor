import XCTest
@testable import BarkVisorCore

final class ConfigTests: XCTestCase {
    func testDefaultPort() {
        XCTAssertEqual(Config.port, 7_777)
    }

    func testAllowedURLSchemes() {
        XCTAssertTrue(Config.allowedURLSchemes.contains("https"))
        XCTAssertTrue(Config.allowedURLSchemes.contains("http"))
        XCTAssertFalse(Config.allowedURLSchemes.contains("ftp"))
        XCTAssertFalse(Config.allowedURLSchemes.contains("file"))
    }

    func testDataDirNotEmpty() {
        let dataDir = Config.dataDir
        XCTAssertFalse(dataDir.path.isEmpty)
        XCTAssertTrue(dataDir.path.localizedCaseInsensitiveContains("barkvisor"))
    }

    func testDBPathIsUnderDataDir() {
        let dbPath = Config.dbPath
        XCTAssertTrue(dbPath.path.hasPrefix(Config.dataDir.path))
        XCTAssertTrue(dbPath.path.hasSuffix("db.sqlite"))
    }

    func testBackupRetentionDaysDefault() {
        // Default should be 30 when UserDefaults has no value
        let days = Config.backupRetentionDays
        XCTAssertGreaterThan(days, 0)
    }

    func testSocketDirPath() {
        let socketDir = Config.socketDir
        XCTAssertTrue(socketDir.path.contains("barkvisor"))
    }

    func testISO8601FormatterAvailable() {
        let date = Date()
        let formatted = iso8601.string(from: date)
        XCTAssertFalse(formatted.isEmpty)

        let parsed = iso8601.date(from: formatted)
        XCTAssertNotNil(parsed)
    }
}
