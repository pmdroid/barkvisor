import Foundation
import GRDB

/// Structured logging for BarkVisor subsystems — writes to the database via LogService
public enum Log {
    public static let server = DBLogger(category: .server)
    public static let vm = DBLogger(category: .vm)
    public static let auth = DBLogger(category: .auth)
    public static let images = DBLogger(category: .images)
    public static let metrics = DBLogger(category: .metrics)
    public static let audit = DBLogger(category: .audit)
    public static let sync = DBLogger(category: .sync)
    public static let app = DBLogger(category: .app)
}

/// Lightweight logger that forwards to LogService (DB + os_log).
/// Drop-in replacement for os.Logger with the same call-site syntax.
public struct DBLogger: Sendable {
    public let category: LogCategory

    public func debug(_ message: String, vm: String? = nil) {
        Task { await LogService.shared.debug(message, category: category, vm: vm) }
    }

    public func info(_ message: String, vm: String? = nil) {
        Task { await LogService.shared.info(message, category: category, vm: vm) }
    }

    public func warning(_ message: String, vm: String? = nil) {
        Task { await LogService.shared.warn(message, category: category, vm: vm) }
    }

    public func error(_ message: String, vm: String? = nil) {
        Task { await LogService.shared.error(message, category: category, vm: vm) }
    }

    public func critical(_ message: String, vm: String? = nil) {
        Task { await LogService.shared.log(.fatal, message, category: category, vm: vm) }
    }
}

/// Shared ISO 8601 date formatter. `ISO8601DateFormatter` is not thread-safe
/// (Linux ICU SIGSEGV under parallel Swift Testing).
public let iso8601 = LockedISO8601Formatter()

public final class LockedISO8601Formatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    public func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

/// Host `systemUptime` when BarkVisorCore first loaded. Subtracted from later
/// readings so diagnostics report **daemon** uptime, not host/OS uptime.
private let processStartSystemUptime = ProcessInfo.processInfo.systemUptime

public enum Config {
    /// Product version reported by About / updates APIs.
    /// Release scripts replace this string at build time (`scripts/lib/inject-version.sh`).
    /// In-tree default marks development builds.
    public static let version = "0.0.0-dev"

    /// True for development / unreleased builds (custom update URL, etc.).
    /// Release tags like `1.2.3` are not dev; `0.0.0-dev` and `0.0.0+git.*` are.
    public static var isDevBuild: Bool {
        version.contains("dev") || version.hasPrefix("0.0.0")
    }

    /// Seconds this BarkVisor process has been running (not host/OS uptime).
    public static var processUptimeSeconds: TimeInterval {
        max(0, ProcessInfo.processInfo.systemUptime - processStartSystemUptime)
    }

    /// HTTP listen port (SPA + JWT). Override with `BARKVISOR_PORT` (1–65535).
    public static let port: Int = {
        if let raw = ProcessInfo.processInfo.environment["BARKVISOR_PORT"],
           let value = Int(raw), value >= 1, value <= 65_535 {
            return value
        }
        return 7_777
    }()

    /// mTLS agent-plane listen port. Override with `BARKVISOR_AGENT_PORT` (1–65535).
    public static let agentPort: Int = {
        if let raw = ProcessInfo.processInfo.environment["BARKVISOR_AGENT_PORT"],
           let value = Int(raw), value >= 1, value <= 65_535 {
            return value
        }
        return 7_778
    }()

    /// Install prefix derived from binary location.
    /// `/usr/local/bin/barkvisor` → prefix = `/usr/local`
    /// Falls back to `/usr/local` for dev builds.
    public static let prefix: String = {
        let bin = ProcessInfo.processInfo.arguments[0]
        let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath()
        let binDir = resolved.deletingLastPathComponent()
        if binDir.lastPathComponent == "bin" {
            return binDir.deletingLastPathComponent().path
        }
        return "/usr/local"
    }()

    /// Installed helper binaries (QEMU, swtpm, socket_vmnet, etc.)
    public static var libexecDir: String {
        "\(prefix)/libexec/barkvisor"
    }

    /// Static assets: frontend dist, QEMU firmware/keymaps, templates
    public static var shareDir: String {
        "\(prefix)/share/barkvisor"
    }

    /// Frontend SPA directory
    public static var frontendDir: String {
        "\(shareDir)/frontend/dist"
    }

    /// QEMU firmware and data directory
    public static var qemuShareDir: String {
        "\(shareDir)/qemu"
    }

    /// Whether running from installed daemon layout (vs. dev build)
    public static var isInstalled: Bool {
        PlatformPaths.isInstalled(libexecDir: libexecDir)
    }

    public static let jwtSecretFileName = "jwt-secret"
    /// HMAC key for API-key hashes. Independent of `jwt-secret` (PAS-277).
    public static let apiKeyHmacSecretFileName = "api-key-hmac-secret"

    public static func jwtSecretFile(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent(jwtSecretFileName)
    }

    public static func apiKeyHmacSecretFile(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent(apiKeyHmacSecretFileName)
    }

    /// Load a previously persisted HMAC secret. Does not create one.
    public static func loadJWTSecret(from dataDir: URL) -> String? {
        let file = jwtSecretFile(in: dataDir)
        guard let data = try? Data(contentsOf: file),
              let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(
                  in: .whitespacesAndNewlines,
              ),
              !existing.isEmpty
        else {
            return nil
        }
        return existing
    }

    /// Load a previously persisted API-key HMAC secret. Does not create one.
    public static func loadAPIKeyHmacSecret(from dataDir: URL) -> String? {
        let file = apiKeyHmacSecretFile(in: dataDir)
        guard let data = try? Data(contentsOf: file),
              let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(
                  in: .whitespacesAndNewlines,
              ),
              !existing.isEmpty
        else {
            return nil
        }
        return existing
    }

    /// Atomic write + 0600. Replaces any existing secret at `dataDir/jwt-secret`.
    public static func persistJWTSecret(_ secret: String, to dataDir: URL) throws {
        let file = jwtSecretFile(in: dataDir)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data(secret.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path,
        )
    }

    /// Atomic write + 0600. Replaces any existing secret at `dataDir/api-key-hmac-secret`.
    public static func persistAPIKeyHmacSecret(_ secret: String, to dataDir: URL) throws {
        let file = apiKeyHmacSecretFile(in: dataDir)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data(secret.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path,
        )
    }

    /// Replace the API-key HMAC secret. Existing key hashes will not verify.
    @discardableResult
    public static func rotateAPIKeyHmacSecret(in dataDir: URL) throws -> String {
        let secret = PlatformRandom.secureBase64(byteCount: 32)
        try persistAPIKeyHmacSecret(secret, to: dataDir)
        return secret
    }

    public static var jwtSecret: String {
        if let existing = loadJWTSecret(from: dataDir) {
            return existing
        }
        // First start: generate and persist
        let secret = PlatformRandom.secureBase64(byteCount: 32)
        do {
            try persistJWTSecret(secret, to: dataDir)
            Log.server.info("Generated and stored JWT secret on disk")
        } catch {
            Log.server.critical(
                """
                Failed to write JWT secret to disk: \(error.localizedDescription). \
                A new secret will be generated on every restart, invalidating all existing sessions.
                """,
            )
        }
        return secret
    }

    /// HMAC key for API keys. Never `jwtSecret`; pairing overwrites of jwt-secret
    /// must not silently invalidate stored API-key hashes (PAS-277).
    public static var apiKeyHmacSecret: String {
        if let existing = loadAPIKeyHmacSecret(from: dataDir) {
            return existing
        }
        let secret = PlatformRandom.secureBase64(byteCount: 32)
        do {
            try persistAPIKeyHmacSecret(secret, to: dataDir)
            Log.server.info("Generated and stored API key HMAC secret on disk")
        } catch {
            Log.server.critical(
                """
                Failed to write API key HMAC secret to disk: \(error.localizedDescription). \
                A new secret will be generated on every restart, invalidating stored API keys.
                """,
            )
        }
        return secret
    }

    /// Allowed URL schemes for repository URLs
    public static let allowedURLSchemes: Set<String> = ["https", "http"]

    public static var dataDir: URL {
        PlatformPaths.dataDir(isInstalled: isInstalled)
    }

    /// Durable host UUID persisted at `dataDir/host-id` (PAS-42).
    public static var hostId: String {
        HostIdentity.loadOrCreate(dataDir: dataDir).uuidString
    }

    /// Short path for unix sockets (must be < 104 bytes)
    public static var socketDir: URL {
        PlatformPaths.socketDir(isInstalled: isInstalled)
    }

    public static var dbPath: URL {
        dataDir.appendingPathComponent("db.sqlite")
    }

    // MARK: - Backup settings

    public static var backupEnabled: Bool {
        PlatformPaths.settingsBool(forKey: "backupEnabled", dataDir: dataDir, default: true)
    }

    public static var backupRetentionDays: Int {
        PlatformPaths.settingsInt(forKey: "backupRetentionDays", dataDir: dataDir, default: 30)
    }

    public static var backupDir: URL {
        let custom = PlatformPaths.settingsString(forKey: "backupDirectory", dataDir: dataDir) ?? ""
        if !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            // Fall back to default if custom directory is inaccessible
            if FileManager.default.isWritableFile(atPath: url.path) {
                return url
            }
            Log.server.warning("Custom backup directory not writable, falling back to default: \(custom)")
        }
        return dataDir.appendingPathComponent("backups")
    }

    // MARK: - Rate limiting

    public static var rateLimitEnabled: Bool {
        PlatformPaths.settingsBool(forKey: "rateLimitEnabled", dataDir: dataDir, default: true)
    }

    public static var rateLimitMaxAttempts: Int {
        PlatformPaths.settingsInt(forKey: "rateLimitMaxAttempts", dataDir: dataDir, default: 10)
    }

    public static var rateLimitWindow: Int {
        PlatformPaths.settingsInt(forKey: "rateLimitWindow", dataDir: dataDir, default: 300)
    }

    // MARK: - Library

    /// Default Library dir (`{dataDir}/images`). The configured path is
    /// `imagesDir(from:)` / `LibrarySettings.resolvedDirectory`.
    public static var imagesDir: URL {
        LibrarySettings.defaultDirectory
    }

    /// Library dir from `app_settings.image_directory`, else `{dataDir}/images`.
    public static func imagesDir(from db: Database) throws -> URL {
        try LibrarySettings.resolvedDirectory(from: db)
    }

    // MARK: - Directories

    public static func ensureDirectories(imagesDir: URL? = nil) throws {
        let fm = FileManager.default
        var dirs = [
            dataDir,
            Self.imagesDir,
            dataDir.appendingPathComponent("disks"),
            dataDir.appendingPathComponent("cloud-init"),
            dataDir.appendingPathComponent("efivars"),
            dataDir.appendingPathComponent("monitor"),
            dataDir.appendingPathComponent("tus-uploads"),
            dataDir.appendingPathComponent("pids"),
            dataDir.appendingPathComponent("console"),
            dataDir.appendingPathComponent(HomeCAService.caDirectoryName),
            dataDir.appendingPathComponent(HomeCAService.agentDirectoryName),
            backupDir,
        ]
        if let imagesDir {
            let custom = imagesDir.standardizedFileURL
            if custom.path != Self.imagesDir.standardizedFileURL.path {
                dirs.append(custom)
            }
        }
        for dir in dirs where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
