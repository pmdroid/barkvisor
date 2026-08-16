import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct LibrarySettingsResponse: Content {
    let imageDirectory: String
    let isDefault: Bool
    let libraryDepotHostId: String?
}

struct LibrarySettingsRequest: Content {
    let imageDirectory: String?
    let libraryDepotHostId: String?
}

/// GET/PUT `/api/system/library/settings` — same stack as update settings
/// (`app_settings` + JWT). Not UserDefaults (`backupDirectory` is broken on Linux).
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
            try LibrarySettings.resolvedDepotHostId(from: db)
        }
        return LibrarySettingsResponse(
            imageDirectory: dir.path,
            isDefault: LibrarySettings.isDefault(dir),
            libraryDepotHostId: depotHostId,
        )
    }

    @Sendable
    func updateSettings(req: Vapor.Request) async throws -> LibrarySettingsResponse {
        let body = try req.content.decode(LibrarySettingsRequest.self)

        if let imageDirectory = body.imageDirectory {
            let prepared = try LibrarySettings.validateAndPrepare(imageDirectory)
            try await req.db.write { db in
                if let prepared {
                    let setting = AppSetting(
                        key: LibrarySettings.imageDirectoryKey,
                        value: prepared.path,
                    )
                    try setting.save(db, onConflict: .replace)
                } else {
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
