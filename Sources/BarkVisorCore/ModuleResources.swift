import Foundation

/// Non-fatal lookup for the SwiftPM module resource bundle.
///
/// The generated `Bundle.module` accessor calls `Swift.fatalError` when it
/// finds neither its installed resource directory nor its build-tree path.
/// Packaging gaps must leave callers with `nil`, so they can use their normal
/// fallback rather than crash-looping the daemon.
enum ModuleResources {
    private static let resourceDirectoryNames = [
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
        dirs.append(
            URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
                .deletingLastPathComponent()
                .standardizedFileURL,
        )

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

    /// The module resource bundle, or `nil` when it cannot be found on disk.
    nonisolated static let resolved: Bundle? = {
        for directory in candidateDirectories() {
            for name in resourceDirectoryNames {
                if let bundle = probe(directory.appendingPathComponent(name, isDirectory: true)) {
                    return bundle
                }
            }
        }
        return nil
    }()
}
