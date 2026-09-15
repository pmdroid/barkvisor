import Foundation

/// Non-fatal lookup for the SwiftPM module resource bundle.
///
/// The generated `Bundle.module` accessor calls `Swift.fatalError` when it
/// finds neither `<Product>_<Module>.bundle` next to the executable nor the
/// baked-in build-tree path. On installs that ship the binary without the
/// bundle (packaging gaps, copied binaries on foreign machines) every hit
/// traps — which crash-looped the daemon via built-in catalog sync.
/// All probes here are nil-safe: `Bundle(path:)` + `resourceURL` never trap.
enum ModuleResources {
    private static let bundleNames = [
        "BarkVisor_BarkVisorCore.bundle",
        "BarkVisor_BarkVisorCore.resources",
    ]

    private final class BundleFinder {}

    private static func probe(_ url: URL) -> Bundle? {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(path: url.path),
              bundle.resourceURL != nil
        else {
            return nil
        }
        return bundle
    }

    private static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        if let viaClass = Bundle(for: BundleFinder.self).resourceURL {
            dirs.append(viaClass)
        }
        dirs.append(Bundle(for: BundleFinder.self).bundleURL)
        dirs.append(Bundle.main.bundleURL)
        let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
            .deletingLastPathComponent()
            .standardizedFileURL
        dirs.append(executableDir)
        // Build-tree layouts (`swift build -c release|debug`), including the
        // triple-suffixed directories some hosts emit under `.build/`.
        // Probe the active configuration first so a stale sibling config's
        // bundle cannot shadow the fresh one in developer trees.
        #if DEBUG
            let layouts = ["debug", "release"]
        #else
            let layouts = ["release", "debug"]
        #endif
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDir = repoRoot.appendingPathComponent(".build", isDirectory: true)
        for layout in layouts {
            dirs.append(buildDir.appendingPathComponent(layout, isDirectory: true))
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: buildDir,
                includingPropertiesForKeys: nil,
            ) {
                for entry in entries {
                    dirs.append(entry.appendingPathComponent(layout, isDirectory: true))
                }
            }
        }
        return dirs
    }

    /// The module resource bundle, or `nil` when it cannot be found on
    /// disk. `nil` means callers must fall back to source-checkout paths
    /// rather than trapping.
    nonisolated static let resolved: Bundle? = {
        for dir in candidateDirectories() {
            for name in bundleNames {
                if let bundle = probe(dir.appendingPathComponent(name, isDirectory: true)) {
                    return bundle
                }
            }
        }
        return nil
    }()
}
