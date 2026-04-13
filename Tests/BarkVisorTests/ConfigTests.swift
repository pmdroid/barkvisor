import Foundation
import Testing
@testable import BarkVisorCore

@Suite struct ConfigTests {
    @Test func defaultPort() {
        #expect(Config.port == 7_777)
    }

    @Test func allowedURLSchemes() {
        #expect(Config.allowedURLSchemes.contains("https"))
        #expect(Config.allowedURLSchemes.contains("http"))
        #expect(!Config.allowedURLSchemes.contains("ftp"))
        #expect(!Config.allowedURLSchemes.contains("file"))
    }

    @Test func dataDirNotEmpty() {
        let dataDir = Config.dataDir
        #expect(!dataDir.path.isEmpty)
        #expect(dataDir.path.localizedCaseInsensitiveContains("barkvisor"))
    }

    @Test func dbPathIsUnderDataDir() {
        let dbPath = Config.dbPath
        #expect(dbPath.path.hasPrefix(Config.dataDir.path))
        #expect(dbPath.path.hasSuffix("db.sqlite"))
    }

    @Test func backupRetentionDaysDefault() {
        let days = Config.backupRetentionDays
        #expect(days > 0)
    }

    @Test func socketDirPath() {
        let socketDir = Config.socketDir
        #expect(socketDir.path.contains("barkvisor"))
    }

    @Test func iso8601FormatterAvailable() {
        let date = Date()
        let formatted = iso8601.string(from: date)
        #expect(!formatted.isEmpty)
        let parsed = iso8601.date(from: formatted)
        #expect(parsed != nil)
    }
}
