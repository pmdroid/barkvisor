import Foundation

/// Centralized binary and resource resolution.
///
/// macOS (PAS-287): Homebrew first (`brew install qemu` / `socket_vmnet` / `swtpm`),
/// then a leftover `{prefix}/libexec/barkvisor/` copy if one exists.
/// Linux: distro FHS, then libexec.
public enum BundleResolver {
    // MARK: - Helpers (executables)

    /// Search order for `helper(_:)`. First existing executable wins.
    public static func helperCandidates(_ name: String) -> [String] {
        let libexec = "\(Config.libexecDir)/\(name)"
        #if os(macOS)
            return [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                libexec,
            ]
        #else
            var candidates = [
                libexec,
                "/usr/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/usr/lib/qemu/\(name)",
                "/usr/libexec/\(name)",
            ]
            if name == "qemu-system-x86_64" {
                candidates += [
                    "/usr/libexec/qemu-kvm",
                    "/usr/bin/qemu-kvm",
                ]
            }
            return candidates
        #endif
    }

    /// Resolve a helper binary by name.
    public static func helper(_ name: String) throws -> URL {
        if let found = firstExecutable(helperCandidates(name)) {
            return URL(fileURLWithPath: found)
        }
        if let found = whichLookup(name) {
            return found
        }
        #if os(macOS)
            let hint = "brew install qemu  (also: brew install swtpm socket_vmnet)"
        #else
            let hint = "install via the distro package manager or ensure it is in PATH"
        #endif
        throw BarkVisorError.processSpawnFailed("\(name) not found. \(hint)")
    }

    /// Search order for Homebrew opt-prefix tools (e.g. socket_vmnet).
    public static func optHelperCandidates(
        _ name: String,
        package: String,
        extraPaths: [String] = [],
    ) -> [String] {
        let libexec = "\(Config.libexecDir)/\(name)"
        var brew = [
            "/opt/homebrew/opt/\(package)/bin/\(name)",
            "/usr/local/opt/\(package)/bin/\(name)",
        ]
        brew.append(contentsOf: extraPaths)
        #if os(macOS)
            return brew + [libexec]
        #else
            return [libexec] + brew
        #endif
    }

    /// Resolve a helper that lives under a Homebrew opt prefix (e.g. socket_vmnet).
    public static func optHelper(_ name: String, package: String, extraPaths: [String] = []) throws
        -> URL {
        if let found = firstExecutable(
            optHelperCandidates(name, package: package, extraPaths: extraPaths),
        ) {
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
    public static func qemuResource(_ name: String) -> URL? {
        #if os(macOS)
            let candidates = [
                "/opt/homebrew/share/qemu/\(name)",
                "/usr/local/share/qemu/\(name)",
                "\(Config.qemuShareDir)/\(name)",
            ]
        #else
            let candidates = [
                "\(Config.qemuShareDir)/\(name)",
                "/opt/homebrew/share/qemu/\(name)",
                "/usr/local/share/qemu/\(name)",
                "/usr/share/qemu/\(name)",
                "/usr/lib/qemu/\(name)",
                "/usr/share/AAVMF/\(name)",
                "/usr/share/OVMF/\(name)",
                "/usr/share/edk2/ovmf/\(name)",
                "/usr/share/edk2/aarch64/\(name)",
            ]
        #endif
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    /// Resolve the QEMU data directory for the `-L` flag.
    public static func qemuDataDir() -> URL? {
        #if os(macOS)
            let candidates = [
                "/opt/homebrew/share/qemu",
                "/usr/local/share/qemu",
                Config.qemuShareDir,
            ]
        #else
            let candidates = [
                Config.qemuShareDir,
                "/opt/homebrew/share/qemu",
                "/usr/local/share/qemu",
                "/usr/share/qemu",
                "/usr/lib/qemu",
            ]
        #endif
        if let found = firstExisting(candidates) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    // MARK: - Private

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
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
