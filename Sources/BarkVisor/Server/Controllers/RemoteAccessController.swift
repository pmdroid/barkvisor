import BarkVisorCore
import Foundation
import GRDB
import Vapor

extension RemoteAccessStatus: Content {}

struct RemoteAccessUpdateRequest: Content {
    var requireTailnetForRemote: Bool?
    var advertiseUrl: String?
}

/// GET `/api/system/remote-access` and PUT `/api/home/settings/remote-access` (PAS-89).
struct RemoteAccessController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "system", "remote-access", use: getStatus)
        routes.put("api", "home", "settings", "remote-access", use: updateSettings)
    }

    @Sendable
    func getStatus(req: Vapor.Request) async throws -> RemoteAccessStatus {
        _ = try req.requireUser
        return try await req.db.read { db in
            try RemoteAccessSettings.status(from: db)
        }
    }

    @Sendable
    func updateSettings(req: Vapor.Request) async throws -> RemoteAccessStatus {
        _ = try req.requireUser
        let body = try req.content.decode(RemoteAccessUpdateRequest.self)
        try await req.db.write { db in
            _ = try RemoteAccessSettings.save(
                requireTailnetForRemote: body.requireTailnetForRemote,
                advertiseUrl: body.advertiseUrl,
                updateAdvertiseUrl: body.advertiseUrl != nil,
                db: db,
            )
        }
        AuditService.log(
            action: "home.settings.remote_access",
            resourceType: "home",
            req: req,
        )
        return try await getStatus(req: req)
    }
}
