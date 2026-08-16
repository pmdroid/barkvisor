import Foundation
import GRDB

/// Per-Device Library path (`image_directory` in `app_settings`).
///
/// New downloads/uploads write here. Existing `images.path` / `disks.path`
/// rows stay put — changing the setting never migrates files.
public enum LibrarySettings {
    public static let imageDirectoryKey = "image_directory"
    public static let libraryDepotHostIdKey = "library_depot_host_id"
    public static let previousDirectoriesKey = "previous_image_directories"

    public static var defaultDirectory: URL {
        Config.dataDir.appendingPathComponent("images")
    }

    public static func isDefault(_ url: URL) -> Bool {
        url.standardizedFileURL.path == defaultDirectory.standardizedFileURL.path
    }

    /// Configured Library dir, or `{dataDir}/images` when unset/empty.
    /// Re-validates the stored path on every read (absolute, no comma).
    public static func resolvedDirectory(from db: Database) throws -> URL {
        let stored = try AppSetting.fetchOne(db, key: imageDirectoryKey)?.value ?? ""
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return defaultDirectory
        }
        guard isAcceptableStoredPath(raw) else {
            return defaultDirectory
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    /// Absolute path that would pass ``validateAndPrepare`` format checks.
    public static func isAcceptableStoredPath(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        return (try? QEMUBuilder.sanitizeQEMUArg(trimmed, label: "Library path")) != nil
    }

    /// Empty/whitespace ⇒ `nil` (reset to default). Otherwise the prepared directory.
    ///
    /// Save-time rules: absolute, no comma (`sanitizeQEMUArg`), writable by the
    /// daemon. Missing directories are created.
    public static func validateAndPrepare(_ raw: String) throws -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        guard trimmed.hasPrefix("/") else {
            throw BarkVisorError.badRequest("Library path must be an absolute path")
        }
        _ = try QEMUBuilder.sanitizeQEMUArg(trimmed, label: "Library path")

        let url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw BarkVisorError.badRequest("Library path must be a directory")
            }
        } else {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw BarkVisorError.badRequest(
                    "Could not create Library path: \(error.localizedDescription)",
                )
            }
        }
        guard fm.isWritableFile(atPath: url.path) else {
            throw BarkVisorError.badRequest("Library path is not writable by the daemon")
        }
        return url
    }

    /// Per-Device Library depot. Empty/whitespace ⇒ no depot (internet only).
    public static func resolvedDepotHostId(from db: Database) throws -> String? {
        let stored = try AppSetting.fetchOne(db, key: libraryDepotHostIdKey)?.value ?? ""
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Empty/whitespace ⇒ `nil` (clear). Otherwise a paired Device or this Device.
    public static func validateDepotHostId(
        _ raw: String?,
        localHostId: String,
        devices: DeviceRegistry,
    ) throws -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if trimmed == localHostId {
            return trimmed
        }
        let members: [DeviceRecord]
        do {
            members = try devices.load()
        } catch {
            throw BarkVisorError.badRequest(
                "Device registry is unavailable; pick this Device or clear the Library depot",
            )
        }
        guard members.contains(where: { $0.hostId == trimmed }) else {
            throw BarkVisorError.badRequest("Library depot must be a paired Device")
        }
        return trimmed
    }

    /// Previous Library dirs (still on disk after the setting moved).
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

    /// Remember a Library dir so later deletes can still unlink files there.
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

    /// Unlink is allowed under `dataDir`, the current Library dir, or a previous one.
    public static func isManagedStoragePath(
        _ path: String,
        imagesDir: URL,
        extraRoots: [URL] = [],
    ) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        if isPath(resolved, under: Config.dataDir) || isPath(resolved, under: imagesDir) {
            return true
        }
        return extraRoots.contains { isPath(resolved, under: $0) }
    }

    public static func isManagedStoragePath(_ path: String, db: Database) throws -> Bool {
        let imagesDir = try resolvedDirectory(from: db)
        let extraRoots = try previousDirectories(from: db)
        return isManagedStoragePath(path, imagesDir: imagesDir, extraRoots: extraRoots)
    }

    public static func isPath(_ resolvedPath: String, under root: URL) -> Bool {
        let canonical = (root.path as NSString).resolvingSymlinksInPath
        if resolvedPath == canonical {
            return true
        }
        let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
        return resolvedPath.hasPrefix(prefix)
    }
}
