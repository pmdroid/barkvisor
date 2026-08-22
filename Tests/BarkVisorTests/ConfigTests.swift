import Foundation
import Testing
@testable import BarkVisorCore

struct ConfigTests {
    @Test func `default port`() {
        #expect(Config.port == 7_777)
    }

    @Test func `default agent port is distinct from spa port`() {
        #expect(Config.agentPort == 7_778)
        #expect(Config.agentPort != Config.port)
    }

    @Test func `allowed URL schemes`() {
        #expect(Config.allowedURLSchemes.contains("https"))
        #expect(Config.allowedURLSchemes.contains("http"))
        #expect(!Config.allowedURLSchemes.contains("ftp"))
        #expect(!Config.allowedURLSchemes.contains("file"))
    }

    @Test func `data dir not empty`() {
        let dataDir = Config.dataDir
        #expect(!dataDir.path.isEmpty)
        #expect(dataDir.path.localizedCaseInsensitiveContains("barkvisor"))
    }

    @Test func `db path is under data dir`() {
        let dbPath = Config.dbPath
        #expect(dbPath.path.hasPrefix(Config.dataDir.path))
        #expect(dbPath.path.hasSuffix("db.sqlite"))
    }

    @Test func `default images dir is under data dir`() {
        #expect(Config.imagesDir.path == Config.dataDir.appendingPathComponent("images").path)
        #expect(LibrarySettings.defaultDirectory.path == Config.imagesDir.path)
    }

    @Test func `backup retention days default`() {
        let days = Config.backupRetentionDays
        #expect(days > 0)
    }

    @Test func `socket dir path`() {
        let socketDir = Config.socketDir
        #expect(socketDir.path.contains("barkvisor"))
    }

    @Test func `iso 8601 formatter available`() {
        let date = Date()
        let formatted = iso8601.string(from: date)
        #expect(!formatted.isEmpty)
        let parsed = iso8601.date(from: formatted)
        #expect(parsed != nil)
    }

    @Test func `process uptime is daemon elapsed not host uptime`() {
        let process = Config.processUptimeSeconds
        let host = ProcessInfo.processInfo.systemUptime
        #expect(process >= 0)
        #expect(process <= host + 0.5)
    }

    @Test func `persist jwt secret does not touch api key hmac secret`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Config.persistAPIKeyHmacSecret("api-keep", to: dir)
        try Config.persistJWTSecret("jwt-new", to: dir)
        #expect(Config.loadJWTSecret(from: dir) == "jwt-new")
        #expect(Config.loadAPIKeyHmacSecret(from: dir) == "api-keep")
        #expect(Config.apiKeyHmacSecretFileName != Config.jwtSecretFileName)
    }

    @Test func `rotate api key hmac secret replaces file with 0600`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Config.persistAPIKeyHmacSecret("before", to: dir)
        try Config.persistJWTSecret("jwt-stays", to: dir)
        let rotated = try Config.rotateAPIKeyHmacSecret(in: dir)
        #expect(rotated != "before")
        #expect(Config.loadAPIKeyHmacSecret(from: dir) == rotated)
        #expect(Config.loadJWTSecret(from: dir) == "jwt-stays")

        let attrs = try FileManager.default.attributesOfItem(
            atPath: Config.apiKeyHmacSecretFile(in: dir).path,
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }
}
