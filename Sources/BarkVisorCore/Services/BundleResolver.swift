import Foundation

/// Centralized binary and resource resolution.
///
/// In a release install, binaries live in `{prefix}/libexec/barkvisor/` and resources
/// (firmware, keymaps) in `{prefix}/share/barkvisor/qemu/`. During development these
/// won't exist, so we fall back to Homebrew / system paths.
public enum BundleResolver {
    // MARK: - Helpers (executables)

    /// Resolve a helper binary by name.
    /// Checks: installed libexec/ → platform bin paths → PATH lookup.
    public static func helper(_ name: String) throws -> URL {
        // 1. Installed location
        let installed = "\(Config.libexecDir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        // 2. Platform search paths (Homebrew on macOS; FHS on Linux)
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        #if os(Linux)
            candidates += [
                "/usr/lib/qemu/\(name)",
                "/usr/libexec/\(name)",
            ]
            // Rocky/Alma/RHEL: qemu-kvm package ships only /usr/libexec/qemu-kvm
            // (no qemu-system-x86_64 binary name).
            if name == "qemu-system-x86_64" {
                candidates += [
                    "/usr/libexec/qemu-kvm",
                    "/usr/bin/qemu-kvm",
                ]
            }
        #endif
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        // 3. PATH search via `which`
        if let found = whichLookup(name) {
            return found
        }
        throw BarkVisorError.processSpawnFailed(
            "\(name) not found. Install via package manager or ensure it is in your PATH.",
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
    /// Checks: installed share/ → Homebrew share → Linux FHS qemu share/lib paths.
    public static func qemuResource(_ name: String) -> URL? {
        // 1. Installed location
        let installed = "\(Config.qemuShareDir)/\(name)"
        if FileManager.default.fileExists(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        // 2. Homebrew / system / Linux FHS (incl. distro firmware dirs)
        let candidates = [
            "/opt/homebrew/share/qemu/\(name)",
            "/usr/local/share/qemu/\(name)",
            "/usr/share/qemu/\(name)",
            "/usr/lib/qemu/\(name)",
            "/usr/share/AAVMF/\(name)",
            "/usr/share/OVMF/\(name)",
            "/usr/share/edk2/ovmf/\(name)",
            "/usr/share/edk2/aarch64/\(name)",
        ]
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    /// Resolve the QEMU data directory for the `-L` flag.
    /// Returns the installed share/qemu/ directory if it exists, otherwise Homebrew/Linux share paths.
    public static func qemuDataDir() -> URL? {
        let installed = Config.qemuShareDir
        if FileManager.default.fileExists(atPath: installed) {
            return URL(fileURLWithPath: installed)
        }
        let candidates = [
            "/opt/homebrew/share/qemu",
            "/usr/local/share/qemu",
            "/usr/share/qemu",
            "/usr/lib/qemu",
        ]
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    // MARK: - Private

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func whichLookup(_ name: String) -> URL? {
        guard let result = try? PlatformProcess.run(
            path: "/usr/bin/which",
            arguments: [name],
            timeout: 5,
        ), result.succeeded else {
            return nil
        }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return URL(fileURLWithPath: output)
    }
}
