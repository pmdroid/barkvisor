import Foundation

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

/// Shared ISO 8601 date formatter — thread-safe, avoids repeated allocation.
public nonisolated(unsafe) let iso8601 = ISO8601DateFormatter()

public enum Config {
    /// INJECT_VERSION (replaced at build time via sed)
    public static let version = "0.0.0-dev"

    /// HTTP listen port. Override with `BARKVISOR_PORT` (1–65535).
    public static let port: Int = {
        if let raw = ProcessInfo.processInfo.environment["BARKVISOR_PORT"],
           let value = Int(raw), value >= 1, value <= 65_535 {
            return value
        }
        return 7_777
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

    /// Bundled shared libraries (dylibs)
    public static var libDir: String {
        "\(prefix)/lib/barkvisor"
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

    private static var secretFile: URL {
        dataDir.appendingPathComponent("jwt-secret")
    }

    public static var jwtSecret: String {
        // Try to load from disk
        if let data = try? Data(contentsOf: secretFile),
           let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(
               in: .whitespacesAndNewlines,
           ),
           !existing.isEmpty {
            return existing
        }
        // First start: generate and persist
        let secret = PlatformRandom.secureBase64(byteCount: 32)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            Log.server.critical(
                """
                Failed to create data directory for JWT secret: \(error.localizedDescription). \
                JWT secret will not be persisted — all sessions will be invalidated on restart.
                """,
            )
        }
        do {
            // Atomic write + 0600 on all platforms (completeFileProtection is macOS-only).
            try Data(secret.utf8).write(to: secretFile, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: secretFile.path,
            )
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

    /// Allowed URL schemes for repository URLs
    public static let allowedURLSchemes: Set<String> = ["https", "http"]

    public static var dataDir: URL {
        PlatformPaths.dataDir(isInstalled: isInstalled)
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

    // MARK: - Directories

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        let dirs = [
            dataDir,
            dataDir.appendingPathComponent("images"),
            dataDir.appendingPathComponent("disks"),
            dataDir.appendingPathComponent("cloud-init"),
            dataDir.appendingPathComponent("efivars"),
            dataDir.appendingPathComponent("monitor"),
            dataDir.appendingPathComponent("tus-uploads"),
            dataDir.appendingPathComponent("pids"),
            dataDir.appendingPathComponent("console"),
            backupDir,
        ]
        for dir in dirs where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
