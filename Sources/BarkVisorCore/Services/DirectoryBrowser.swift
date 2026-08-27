import Foundation

public enum DirectoryBrowser {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public static let volumeRoots: [String] = ["/Volumes", "/mnt", "/media"]

    public static func staticRoots(home: String = NSHomeDirectory()) -> [String] {
        [home] + volumeRoots
    }

    public static func isAllowed(
        _ path: String,
        extraRoots: [String] = [],
        home: String = NSHomeDirectory(),
    ) -> Bool {
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        let roots = staticRoots(home: home) + extraRoots
        let inRoot = roots.contains { root in
            let canonical = (root as NSString).resolvingSymlinksInPath
            let rootWithSlash = canonical.hasSuffix("/") ? canonical : canonical + "/"
            return resolvedPath == canonical || resolvedPath.hasPrefix(rootWithSlash)
        }
        return inRoot || resolvedPath == "/"
    }

    public static func rootEntries(
        extraRoots: [String] = [],
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        },
    ) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for root in staticRoots(home: home) + extraRoots {
            let resolved = (root as NSString).resolvingSymlinksInPath
            guard isAllowed(resolved, extraRoots: extraRoots, home: home) else { continue }
            guard exists(resolved) else { continue }
            if seen.contains(resolved) { continue }
            seen.insert(resolved)
            let name = (resolved as NSString).lastPathComponent
            entries.append(Entry(name: name.isEmpty ? resolved : name, path: resolved))
        }
        return entries
    }

    public static func list(
        path rawPath: String,
        extraRoots: [String] = [],
        home: String = NSHomeDirectory(),
    ) throws -> [Entry] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return rootEntries(extraRoots: extraRoots, home: home)
        }

        let resolvedPath = (trimmed as NSString).resolvingSymlinksInPath
        guard isAllowed(resolvedPath, extraRoots: extraRoots, home: home) else {
            throw BarkVisorError.forbidden("Access denied: path is outside allowed directories")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue
        else {
            throw BarkVisorError.badRequest("Path is not a directory")
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
        var entries: [Entry] = []

        if let parent = parentPath(of: resolvedPath, extraRoots: extraRoots, home: home) {
            entries.append(Entry(name: "..", path: parent))
        }

        for name in contents.sorted() {
            if name.hasPrefix(".") { continue }
            let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &childIsDir)
            guard childIsDir.boolValue else { continue }
            guard isAllowed(fullPath, extraRoots: extraRoots, home: home) else { continue }
            entries.append(Entry(name: name, path: fullPath))
        }

        return entries
    }

    public static func parentPath(
        of path: String,
        extraRoots: [String] = [],
        home: String = NSHomeDirectory(),
    ) -> String? {
        let resolved = (path as NSString).resolvingSymlinksInPath
        if resolved == "/" { return nil }
        let parent = (resolved as NSString).deletingLastPathComponent
        if isAllowed(parent, extraRoots: extraRoots, home: home) {
            return parent
        }
        return ""
    }
}
