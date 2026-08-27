import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct LibrarySettingsResponse: Content {
    let imageDirectory: String
    let isDefault: Bool
    let libraryDepotHostId: String?
    /// Volume that contains `imageDirectory`. Nil when unreadable — never 0 as a stand-in.
    let totalBytes: UInt64?
    let freeBytes: UInt64?
    /// `totalBytes - freeBytes` when both are present.
    let usedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case imageDirectory
        case isDefault
        case libraryDepotHostId
        case totalBytes
        case freeBytes
        case usedBytes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(imageDirectory, forKey: .imageDirectory)
        try container.encode(isDefault, forKey: .isDefault)
        if let libraryDepotHostId {
            try container.encode(libraryDepotHostId, forKey: .libraryDepotHostId)
        } else {
            try container.encodeNil(forKey: .libraryDepotHostId)
        }
        // Always emit volume keys so clients can tell "unknown" from an omitted
        // field. Unknown → JSON null, never 0.
        if let totalBytes {
            try container.encode(totalBytes, forKey: .totalBytes)
        } else {
            try container.encodeNil(forKey: .totalBytes)
        }
        if let freeBytes {
            try container.encode(freeBytes, forKey: .freeBytes)
        } else {
            try container.encodeNil(forKey: .freeBytes)
        }
        if let usedBytes {
            try container.encode(usedBytes, forKey: .usedBytes)
        } else {
            try container.encodeNil(forKey: .usedBytes)
        }
    }
}

struct LibrarySettingsRequest: Content {
    let imageDirectory: String?
    let libraryDepotHostId: String?
}

/// GET/PUT `/api/system/library/settings` — same stack as update settings
/// (`app_settings` + JWT). Not UserDefaults (`backupDirectory` is broken on Linux).
///
/// GET reports **this Device's** Library volume (`totalBytes` / `freeBytes` /
/// `usedBytes` for `imageDirectory`). The Library depot is another Device; its
/// volume is not included. Home proxy
/// `GET /api/home/devices/{id}/v1/system/library/settings` can read a member's
/// own Library when that Device is reachable — do not invent 0,0 if it is not.
struct LibrarySettingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let library = routes.grouped("api", "system", "library")
        library.get("settings", use: getSettings)
        library.put("settings", use: updateSettings)
    }

    @Sendable
    func getSettings(req: Vapor.Request) async throws -> LibrarySettingsResponse {
        let dir = try await req.db.read { db in
            try LibrarySettings.resolvedDirectory(from: db)
        }
        let depotHostId = try await req.db.read { db in
            try LibrarySettings.resolvedDepotHostId(
                from: db,
                devices: DeviceRegistry(dataDir: Config.dataDir),
                localHostId: Config.hostId,
            )
        }
        let usage = LibrarySettings.volumeUsage(at: dir)
        let totalBytes = usage?.total
        let freeBytes = usage?.free
        return LibrarySettingsResponse(
            imageDirectory: dir.path,
            isDefault: LibrarySettings.isDefault(dir),
            libraryDepotHostId: depotHostId,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            usedBytes: LibrarySettings.usedBytes(total: totalBytes, free: freeBytes),
        )
    }

    @Sendable
    func updateSettings(req: Vapor.Request) async throws -> LibrarySettingsResponse {
        let body = try req.content.decode(LibrarySettingsRequest.self)

        if let imageDirectory = body.imageDirectory {
            let prepared = try LibrarySettings.validateAndPrepare(imageDirectory)
            try await req.db.write { db in
                let previous = try LibrarySettings.resolvedDirectory(from: db)
                if let prepared {
                    if previous.standardizedFileURL.path != prepared.standardizedFileURL.path {
                        try LibrarySettings.recordPreviousDirectory(previous, db: db)
                    }
                    let setting = AppSetting(
                        key: LibrarySettings.imageDirectoryKey,
                        value: prepared.path,
                    )
                    try setting.save(db, onConflict: .replace)
                } else {
                    try LibrarySettings.recordPreviousDirectory(previous, db: db)
                    _ = try AppSetting.deleteOne(db, key: LibrarySettings.imageDirectoryKey)
                }
            }
            try Config.ensureDirectories(
                imagesDir: prepared ?? LibrarySettings.defaultDirectory,
            )
        }

        if let libraryDepotHostId = body.libraryDepotHostId {
            let validated = try LibrarySettings.validateDepotHostId(
                libraryDepotHostId,
                localHostId: Config.hostId,
                devices: DeviceRegistry(dataDir: Config.dataDir),
            )
            try await req.db.write { db in
                if let validated {
                    let setting = AppSetting(
                        key: LibrarySettings.libraryDepotHostIdKey,
                        value: validated,
                    )
                    try setting.save(db, onConflict: .replace)
                } else {
                    _ = try AppSetting.deleteOne(db, key: LibrarySettings.libraryDepotHostIdKey)
                }
            }
        }

        return try await getSettings(req: req)
    }
}
