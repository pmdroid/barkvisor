import Foundation

/// Host folder picker roots. `$HOME` and `/Volumes` plus the configured Library.
public enum DirectoryBrowser {
    public static let staticRoots: [String] = [
        NSHomeDirectory(),
        "/Volumes",
    ]

    public static func isAllowed(_ path: String, extraRoots: [String] = []) -> Bool {
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        let roots = staticRoots + extraRoots
        let inRoot = roots.contains { root in
            let canonical = (root as NSString).resolvingSymlinksInPath
            let rootWithSlash = canonical.hasSuffix("/") ? canonical : canonical + "/"
            return resolvedPath == canonical || resolvedPath.hasPrefix(rootWithSlash)
        }
        return inRoot || resolvedPath == "/"
    }
}
