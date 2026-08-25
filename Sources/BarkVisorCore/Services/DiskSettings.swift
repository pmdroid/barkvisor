import Foundation
import GRDB

public enum DiskSettings {
    public static let directoryKey = "disk_directory"
    public static let previousDirectoriesKey = "previous_disk_directories"

    public static var defaultDirectory: URL {
        Config.dataDir.appendingPathComponent("disks")
    }

    public static func isDefault(_ url: URL) -> Bool {
        url.standardizedFileURL.path == defaultDirectory.standardizedFileURL.path
    }

    public static func resolvedDirectory(from db: Database) throws -> URL {
        let stored = try AppSetting.fetchOne(db, key: directoryKey)?.value ?? ""
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return defaultDirectory
        }
        guard isAcceptableStoredPath(raw) else {
            return defaultDirectory
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    public static func isAcceptableStoredPath(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        if isHostDevicePath(trimmed) { return false }
        return (try? QEMUBuilder.sanitizeQEMUArg(trimmed, label: "Disk directory")) != nil
    }

    public static func validateAndPrepare(_ raw: String) throws -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        guard trimmed.hasPrefix("/") else {
            throw BarkVisorError.badRequest("Disk directory must be an absolute path")
        }
        if isHostDevicePath(trimmed) {
            throw BarkVisorError.badRequest("Disk directory cannot be a host device path")
        }
        _ = try QEMUBuilder.sanitizeQEMUArg(trimmed, label: "Disk directory")

        let url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw BarkVisorError.badRequest("Disk directory must be a directory")
            }
        } else {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw BarkVisorError.badRequest(
                    "Could not create disk directory: \(error.localizedDescription)",
                )
            }
        }
        guard fm.isWritableFile(atPath: url.path) else {
            throw BarkVisorError.badRequest("Disk directory is not writable by the daemon")
        }
        return url
    }

    public static func previousDirectories(from db: Database) throws -> [URL] {
        let stored = try AppSetting.fetchOne(db, key: previousDirectoriesKey)?.value ?? ""
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        let paths = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAcceptableStoredPath(trimmed) else { return nil }
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
    }

    public static func recordPreviousDirectory(_ url: URL, db: Database) throws {
        guard !isDefault(url) else { return }
        let path = url.standardizedFileURL.path
        guard isAcceptableStoredPath(path) else { return }
        var paths = try previousDirectories(from: db).map(\.path)
        if !paths.contains(path) {
            paths.append(path)
        }
        if paths.count > 8 {
            paths = Array(paths.suffix(8))
        }
        let data = try JSONEncoder().encode(paths)
        let encoded = String(data: data, encoding: .utf8) ?? "[]"
        try AppSetting(key: previousDirectoriesKey, value: encoded).save(db, onConflict: .replace)
    }

    public static func isManagedStoragePath(
        _ path: String,
        disksDir: URL,
        extraRoots: [URL] = [],
    ) -> Bool {
        if isHostDevicePath(path) { return false }
        let resolved = (path as NSString).resolvingSymlinksInPath
        if LibrarySettings.isPath(resolved, under: disksDir) {
            return true
        }
        return extraRoots.contains { LibrarySettings.isPath(resolved, under: $0) }
    }

    public static func isManagedStoragePath(_ path: String, db: Database) throws -> Bool {
        let disksDir = try resolvedDirectory(from: db)
        let extraRoots = try previousDirectories(from: db)
        return isManagedStoragePath(path, disksDir: disksDir, extraRoots: extraRoots)
    }

    public static func fileURL(id: String, format: String, directory: URL) -> URL {
        let ext = format == "raw" ? "img" : "qcow2"
        return directory.appendingPathComponent("\(id).\(ext)")
    }

    public static func isHostDevicePath(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        return resolved == "/dev" || resolved.hasPrefix("/dev/")
    }
}
