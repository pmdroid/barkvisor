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

    /// Homebrew LaunchDaemon runs as root (`/var/root`); expose login homes for folder pickers.
    private static let rootDaemonHome = "/var/root"

    public static func staticRoots(home: String = NSHomeDirectory()) -> [String] {
        var roots = [home] + volumeRoots
        #if os(macOS)
            if home == rootDaemonHome, !roots.contains("/Users") {
                roots.append("/Users")
            }
        #endif
        return roots
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

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
        } catch {
            if isPermissionError(error) {
                throw BarkVisorError.permissionDenied(permissionDeniedMessage())
            }
            throw BarkVisorError.badRequest(
                "Could not read this folder: \((error as NSError).localizedDescription)",
            )
        }
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

    public static func createFolder(
        parentPath rawParent: String,
        name rawName: String,
        extraRoots: [String] = [],
        home: String = NSHomeDirectory(),
    ) throws -> Entry {
        let parent = rawParent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty else {
            throw BarkVisorError.badRequest("Open a folder before creating a subfolder")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw BarkVisorError.badRequest("Folder name is required")
        }
        guard name != "..", !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else {
            throw BarkVisorError.badRequest("Invalid folder name")
        }

        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        guard isAllowed(resolvedParent, extraRoots: extraRoots, home: home) else {
            throw BarkVisorError.forbidden("Access denied: path is outside allowed directories")
        }

        var parentIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedParent, isDirectory: &parentIsDir),
              parentIsDir.boolValue
        else {
            throw BarkVisorError.badRequest("Parent path is not a directory")
        }

        let newPath = (resolvedParent as NSString).appendingPathComponent(name)
        guard isAllowed(newPath, extraRoots: extraRoots, home: home) else {
            throw BarkVisorError.forbidden("Access denied: path is outside allowed directories")
        }
        if FileManager.default.fileExists(atPath: newPath) {
            throw BarkVisorError.badRequest("A file or folder with that name already exists")
        }
        try FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: false)
        return Entry(name: name, path: newPath)
    }

    public static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue
           || nsError.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.EACCES.rawValue)
           || nsError.code == Int(POSIXErrorCode.EPERM.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    public static func permissionDeniedMessage() -> String {
        #if os(macOS)
            return "macOS denied access to this folder. Grant BarkVisor Full Disk Access in "
                + "System Settings > Privacy & Security > Full Disk Access, then try again."
        #else
            return "Permission denied reading this folder. Adjust its permissions so the "
                + "BarkVisor daemon user can read it."
        #endif
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
