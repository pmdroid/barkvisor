import Foundation
import Testing
@testable import BarkVisorCore

struct ConfigTests {
    @Test func `default port`() {
        #expect(Config.port == 7_777)
    }

    @Test func `listenPort zero is ephemeral`() {
        #expect(Config.listenPort(from: "0", fallback: 7_777) == 0)
        #expect(Config.listenPort(from: " 0 ", fallback: 7_777) == 0)
        #expect(Config.listenPort(from: "8080", fallback: 7_777) == 8_080)
        #expect(Config.listenPort(from: nil, fallback: 7_777) == 7_777)
        #expect(Config.listenPort(from: "", fallback: 7_777) == 7_777)
        #expect(Config.listenPort(from: "-1", fallback: 7_777) == 7_777)
        #expect(Config.listenPort(from: "65536", fallback: 7_777) == 7_777)
    }

    @Test func `daemon role from executable name`() {
        #expect(DaemonRole.from(executablePath: "/usr/local/bin/barkvisor") == .home)
        #expect(DaemonRole.from(executablePath: "barkvisor") == .home)
        #expect(DaemonRole.from(executablePath: "/usr/local/bin/barkvisor-agent") == .agent)
        #expect(DaemonRole.from(executablePath: "barkvisor-agent") == .agent)
        #expect(DaemonRole.from(executablePath: "/.build/debug/BarkVisorApp") == .home)
        #expect(DaemonRole.from(executablePath: "/usr/local/bin/barkvisor").commandName == "barkvisor")
        #expect(DaemonRole.from(executablePath: "barkvisor-agent").commandName == "barkvisor-agent")
        #expect(DaemonRole.from(executablePath: "barkvisor").serveFrontend)
        #expect(!DaemonRole.from(executablePath: "barkvisor-agent").serveFrontend)
    }

    @Test func `default agent port is distinct from spa port`() {
        #expect(Config.agentPort == 7_778)
        #expect(Config.agentPort != Config.port)
        #expect(Config.listenPort(from: "0", fallback: 7_778) == 0)
        #expect(Config.listenPort(from: "7778", fallback: 7_778) == 7_778)
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

    @Test func `default disks dir is under data dir`() {
        #expect(Config.disksDir.path == Config.dataDir.appendingPathComponent("disks").path)
        #expect(DiskSettings.defaultDirectory.path == Config.disksDir.path)
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

    @Test func `ensure api key hmac secret reports first generation then reuse`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = Config.ensureAPIKeyHmacSecret(in: dir)
        #expect(first.generated)
        #expect(!first.secret.isEmpty)
        #expect(Config.loadAPIKeyHmacSecret(from: dir) == first.secret)

        let again = Config.ensureAPIKeyHmacSecret(in: dir)
        #expect(!again.generated)
        #expect(again.secret == first.secret)

        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try Config.persistAPIKeyHmacSecret("pre-existing", to: other)
        let loaded = Config.ensureAPIKeyHmacSecret(in: other)
        #expect(!loaded.generated)
        #expect(loaded.secret == "pre-existing")
    }

    @Test func `ensure api key hmac secret persist failure is not generated`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // `dataDir` is a file, so persist cannot create `api-key-hmac-secret`.
        let blocked = dir.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)

        let result = Config.ensureAPIKeyHmacSecret(in: blocked)
        #expect(!result.generated)
        #expect(!result.secret.isEmpty)
        #expect(Config.loadAPIKeyHmacSecret(from: blocked) == nil)
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

    @Test func `persist hmac and jwt secrets are 0600`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Config.persistAPIKeyHmacSecret("hmac", to: dir)
        try Config.persistJWTSecret("jwt", to: dir)

        for path in [
            Config.apiKeyHmacSecretFile(in: dir).path,
            Config.jwtSecretFile(in: dir).path,
        ] {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            #expect(perms & 0o777 == 0o600)
        }
    }

    @Test func `persist hmac secret can replace an existing file`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Config.persistAPIKeyHmacSecret("first", to: dir)
        try Config.persistAPIKeyHmacSecret("second", to: dir)
        #expect(Config.loadAPIKeyHmacSecret(from: dir) == "second")
        try Config.persistJWTSecret("jwt-a", to: dir)
        try Config.persistJWTSecret("jwt-b", to: dir)
        #expect(Config.loadJWTSecret(from: dir) == "jwt-b")
    }

    @Test func `ensure api key hmac secret concurrent callers share one secret`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        final class LockedSecrets: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []

            func append(_ secret: String) {
                lock.lock()
                values.append(secret)
                lock.unlock()
            }

            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        let secrets = LockedSecrets()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let result = Config.ensureAPIKeyHmacSecret(in: dir)
            secrets.append(result.secret)
        }
        let collected = secrets.snapshot()
        #expect(Set(collected).count == 1)
        #expect(Config.loadAPIKeyHmacSecret(from: dir) == collected[0])
        #expect(!collected[0].isEmpty)
    }
}
