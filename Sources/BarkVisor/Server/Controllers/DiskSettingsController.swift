import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct DiskSettingsResponse: Content {
    let diskDirectory: String
    let isDefault: Bool
}

struct DiskSettingsRequest: Content {
    let diskDirectory: String?
}

struct DiskSettingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let disk = routes.grouped("api", "system", "disk")
        disk.get("settings", use: getSettings)
        disk.put("settings", use: updateSettings)
    }

    @Sendable
    func getSettings(req: Vapor.Request) async throws -> DiskSettingsResponse {
        let dir = try await req.db.read { db in
            try DiskSettings.resolvedDirectory(from: db)
        }
        return DiskSettingsResponse(
            diskDirectory: dir.path,
            isDefault: DiskSettings.isDefault(dir),
        )
    }

    @Sendable
    func updateSettings(req: Vapor.Request) async throws -> DiskSettingsResponse {
        let body = try req.content.decode(DiskSettingsRequest.self)
        guard let diskDirectory = body.diskDirectory else {
            return try await getSettings(req: req)
        }
        let prepared = try DiskSettings.validateAndPrepare(diskDirectory)
        try await req.db.write { db in
            let previous = try DiskSettings.resolvedDirectory(from: db)
            if let prepared {
                if previous.standardizedFileURL.path != prepared.standardizedFileURL.path {
                    try DiskSettings.recordPreviousDirectory(previous, db: db)
                }
                let setting = AppSetting(
                    key: DiskSettings.directoryKey,
                    value: prepared.path,
                )
                try setting.save(db, onConflict: .replace)
            } else {
                try DiskSettings.recordPreviousDirectory(previous, db: db)
                _ = try AppSetting.deleteOne(db, key: DiskSettings.directoryKey)
            }
        }
        try Config.ensureDirectories(
            disksDir: prepared ?? DiskSettings.defaultDirectory,
        )
        return try await getSettings(req: req)
    }
}
