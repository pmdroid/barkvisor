import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct LibrarySettingsResponse: Content {
    let imageDirectory: String
    let isDefault: Bool
    /// Volume that contains `imageDirectory`. Nil when unreadable — never 0 as a stand-in.
    let totalBytes: UInt64?
    let freeBytes: UInt64?
    /// `totalBytes - freeBytes` when both are present.
    let usedBytes: UInt64?
    let lastSyncedAt: String?

    enum CodingKeys: String, CodingKey {
        case imageDirectory
        case isDefault
        case totalBytes
        case freeBytes
        case usedBytes
        case lastSyncedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(imageDirectory, forKey: .imageDirectory)
        try container.encode(isDefault, forKey: .isDefault)
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
        if let lastSyncedAt {
            try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
        } else {
            try container.encodeNil(forKey: .lastSyncedAt)
        }
    }
}

struct LibrarySettingsRequest: Content {
    let imageDirectory: String?
}

/// GET/PUT `/api/system/library/settings` — same stack as update settings
/// (`app_settings` + JWT). Not UserDefaults (`backupDirectory` is broken on Linux).
///
/// GET reports **this Device's** Library volume (`totalBytes` / `freeBytes` /
/// `usedBytes` for `imageDirectory`). Home proxy
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
        try await Self.load(req: req)
    }

    static func load(req: Vapor.Request) async throws -> LibrarySettingsResponse {
        let snapshot = try await req.db.read { db in
            try (
                dir: LibrarySettings.resolvedDirectory(from: db),
                explicit: LibrarySettings.hasExplicitDirectory(from: db),
                lastSyncedAt: ImageRepository.builtInLastSyncedAt(db),
            )
        }
        let usage = LibrarySettings.volumeUsage(at: snapshot.dir)
        let totalBytes = usage?.total
        let freeBytes = usage?.free
        return LibrarySettingsResponse(
            imageDirectory: snapshot.dir.path,
            isDefault: !snapshot.explicit,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            usedBytes: LibrarySettings.usedBytes(total: totalBytes, free: freeBytes),
            lastSyncedAt: snapshot.lastSyncedAt,
        )
    }

    @Sendable
    func updateSettings(req: Vapor.Request) async throws -> LibrarySettingsResponse {
        let body = try req.content.decode(LibrarySettingsRequest.self)
        return try await Self.apply(req: req, body: body)
    }

    static func apply(
        req: Vapor.Request,
        body: LibrarySettingsRequest,
    ) async throws -> LibrarySettingsResponse {
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

        return try await load(req: req)
    }
}
