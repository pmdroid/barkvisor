import Foundation

/// Centralized binary and resource resolution.
///
/// In a release install, binaries live in `{prefix}/libexec/barkvisor/` and resources
/// (firmware, keymaps) in `{prefix}/share/barkvisor/qemu/`. During development these
/// won't exist, so we fall back to Homebrew / system paths.
public enum BundleResolver {
    // MARK: - Helpers (executables)

    /// Resolve a helper binary by name.
    /// Checks: installed libexec/ → /opt/homebrew/bin → /usr/local/bin → PATH lookup.
    public static func helper(_ name: String) throws -> URL {
        // 1. Installed location
        let installed = "\(Config.libexecDir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        // 2. Homebrew / system
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        // 3. PATH search via `which`
        if let found = whichLookup(name) {
            return found
        }
        throw BarkVisorError.processSpawnFailed(
            "\(name) not found. Install via Homebrew or ensure it is in your PATH.",
        )
    }

    /// Resolve a helper that lives under a Homebrew opt prefix (e.g. socket_vmnet).
    /// Checks: installed libexec/ → /opt/homebrew/opt/{package}/bin → /usr/local/opt/{package}/bin → custom paths.
    public static func optHelper(_ name: String, package: String, extraPaths: [String] = []) throws
        -> URL {
        let installed = "\(Config.libexecDir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        var candidates = [
            "/opt/homebrew/opt/\(package)/bin/\(name)",
            "/usr/local/opt/\(package)/bin/\(name)",
        ]
        candidates.append(contentsOf: extraPaths)
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        throw BarkVisorError.processSpawnFailed(
            "\(name) not found. Install via: brew install \(package)",
        )
    }

    /// Resolve a system binary (e.g. gunzip, curl). These are never bundled.
    public static func system(_ name: String) throws -> URL {
        let candidates = [
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        throw BarkVisorError.processSpawnFailed("\(name) not found at expected system path.")
    }

    // MARK: - Resources (firmware, data files)

    /// Resolve a QEMU resource file (firmware, vgabios, keymaps, etc.).
    /// Checks: installed share/ → /opt/homebrew/share/qemu → /usr/local/share/qemu.
    public static func qemuResource(_ name: String) -> URL? {
        // 1. Installed location
        let installed = "\(Config.qemuShareDir)/\(name)"
        if FileManager.default.fileExists(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        // 2. Homebrew / system
        let candidates = [
            "/opt/homebrew/share/qemu/\(name)",
            "/usr/local/share/qemu/\(name)",
        ]
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    /// Resolve the QEMU data directory for the `-L` flag.
    /// Returns the installed share/qemu/ directory if it exists, otherwise the Homebrew share path.
    public static func qemuDataDir() -> URL? {
        let installed = Config.qemuShareDir
        if FileManager.default.fileExists(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        let candidates = [
            "/opt/homebrew/share/qemu",
            "/usr/local/share/qemu",
        ]
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    /// Whether we're running from an installed layout (as opposed to `swift run` development).
    public static var isBundle: Bool {
        Config.isInstalled
    }

    // MARK: - Private

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func whichLookup(_ name: String) -> URL? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let output =
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if which.terminationStatus == 0, !output.isEmpty {
                return URL(fileURLWithPath: output)
            }
        } catch {}
        return nil
    }
}
