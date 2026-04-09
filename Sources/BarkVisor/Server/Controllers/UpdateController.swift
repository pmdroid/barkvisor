import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct UpdateSettingsResponse: Content {
    let channel: String
    let autoCheck: Bool
    let isDevBuild: Bool
    let updateURL: String?
}

struct UpdateSettingsRequest: Content {
    let channel: String?
    let autoCheck: Bool?
    let updateURL: String?
}

// TODO: restore `Config.version.contains("dev")` once release versioning is in place
private var isDevBuild: Bool {
    true
}

struct UpdateCheckResponse: Content {
    let currentVersion: String
    let update: UpdateInfo?
}

struct UpdateInstallRequest: Content {
    let version: String
}

struct UpdateController: RouteCollection {
    let updateService: UpdateService
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let updates = routes.grouped("api", "system", "updates")
        updates.get("check", use: checkForUpdates)
        updates.post("install", use: installUpdate)
        updates.get("settings", use: getSettings)
        updates.put("settings", use: updateSettings)
    }

    @Sendable
    func checkForUpdates(req: Vapor.Request) async throws -> UpdateCheckResponse {
        let (channelSetting, urlSetting) = try await req.db.read { db in
            let channel = try AppSetting.fetchOne(db, key: "update_channel")
            let url = try AppSetting.fetchOne(db, key: "update_url")
            return (channel, url)
        }
        let channel = UpdateChannel(rawValue: channelSetting?.value ?? "stable") ?? .stable
        let urlOverride = isDevBuild ? urlSetting?.value : nil

        let update = try await updateService.checkForUpdates(channel: channel, urlOverride: urlOverride)
        return UpdateCheckResponse(
            currentVersion: Config.version,
            update: update,
        )
    }

    @Sendable
    func installUpdate(req: Vapor.Request) async throws -> TaskAcceptedResponse {
        let body = try req.content.decode(UpdateInstallRequest.self)

        // Look up channel and URL override from settings (same as checkForUpdates)
        let (channelSetting, urlSetting) = try await req.db.read { db in
            let channel = try AppSetting.fetchOne(db, key: "update_channel")
            let url = try AppSetting.fetchOne(db, key: "update_url")
            return (channel, url)
        }
        let channel = UpdateChannel(rawValue: channelSetting?.value ?? "stable") ?? .stable
        let urlOverride = isDevBuild ? urlSetting?.value : nil

        // Look up the release from GitHub instead of trusting URLs from the request
        let release = try await updateService.lookupRelease(
            version: body.version,
            channel: channel,
            urlOverride: urlOverride,
        )

        let taskID = "system-update-\(release.version)"
        let tasks = backgroundTasks

        await tasks.submit(taskID, kind: .systemUpdate) { [release] in
            try await updateService.downloadAndInstall(release: release) { progress in
                await tasks.reportProgress(taskID, progress: progress)
            }
            return nil
        }

        AuditService.log(
            action: "system.update", resourceType: "system", resourceId: nil,
            resourceName: "v\(release.version)", req: req,
        )

        return TaskAcceptedResponse(taskID: taskID)
    }

    @Sendable
    func getSettings(req: Vapor.Request) async throws -> UpdateSettingsResponse {
        let settings = try await req.db.read { db -> (String?, String?, String?) in
            let channel = try AppSetting.fetchOne(db, key: "update_channel")
            let autoCheck = try AppSetting.fetchOne(db, key: "update_auto_check")
            let url = try AppSetting.fetchOne(db, key: "update_url")
            return (channel?.value, autoCheck?.value, url?.value)
        }
        return UpdateSettingsResponse(
            channel: settings.0 ?? "stable",
            autoCheck: settings.1 == "true",
            isDevBuild: isDevBuild,
            updateURL: isDevBuild ? settings.2 : nil,
        )
    }

    @Sendable
    func updateSettings(req: Vapor.Request) async throws -> UpdateSettingsResponse {
        let body = try req.content.decode(UpdateSettingsRequest.self)

        try await req.db.write { db in
            if let channel = body.channel {
                guard channel == "stable" || channel == "beta" else {
                    throw Abort(.badRequest, reason: "Invalid channel: must be 'stable' or 'beta'")
                }
                let setting = AppSetting(key: "update_channel", value: channel)
                try setting.save(db, onConflict: .replace)
            }
            if let autoCheck = body.autoCheck {
                let setting = AppSetting(key: "update_auto_check", value: autoCheck ? "true" : "false")
                try setting.save(db, onConflict: .replace)
            }
            if isDevBuild, let url = body.updateURL {
                let setting = AppSetting(key: "update_url", value: url)
                try setting.save(db, onConflict: .replace)
            }
        }

        return try await getSettings(req: req)
    }
}
