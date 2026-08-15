import Foundation
import GRDB

/// Per-Device Library path (`image_directory` in `app_settings`).
///
/// New downloads/uploads write here. Existing `images.path` / `disks.path`
/// rows stay put — changing the setting never migrates files.
public enum LibrarySettings {
    public static let imageDirectoryKey = "image_directory"
    public static let libraryDepotHostIdKey = "library_depot_host_id"

    public static var defaultDirectory: URL {
        Config.dataDir.appendingPathComponent("images")
    }

    public static func isDefault(_ url: URL) -> Bool {
        url.standardizedFileURL.path == defaultDirectory.standardizedFileURL.path
    }

    /// Configured Library dir, or `{dataDir}/images` when unset/empty.
    public static func resolvedDirectory(from db: Database) throws -> URL {
        let stored = try AppSetting.fetchOne(db, key: imageDirectoryKey)?.value ?? ""
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return defaultDirectory
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
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

    /// Unlink is allowed under `dataDir` or the configured Library dir.
    public static func isManagedStoragePath(_ path: String, imagesDir: URL) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        return isPath(resolved, under: Config.dataDir) || isPath(resolved, under: imagesDir)
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
