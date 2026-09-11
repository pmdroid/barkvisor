import BarkVisorCore
import Vapor

struct SecuritySettingsResponse: Content {
    let authMode: String
    let persistedAuthMode: String
    let envLocked: Bool
}

struct SecuritySettingsRequest: Content {
    let authMode: String
    var acknowledged: Bool?
}

struct SecuritySettingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let security = routes.grouped("api", "settings", "security")
        security.get(use: getSettings)
        security.put(use: updateSettings)
    }

    @Sendable
    func getSettings(req: Request) async throws -> SecuritySettingsResponse {
        _ = try Self.requireAdmin(req)
        return Self.snapshot()
    }

    @Sendable
    func updateSettings(req: Request) async throws -> SecuritySettingsResponse {
        _ = try Self.requireAdmin(req)
        let body = try req.content.decode(SecuritySettingsRequest.self)
        guard let mode = AuthModeStore.parse(body.authMode) else {
            throw BarkVisorError.badRequest("authMode must be secure, loopback, or disabled")
        }
        if mode == .disabled, body.acknowledged != true {
            throw BarkVisorError.badRequest(
                "Disabling sign-in for the whole network requires acknowledged=true",
            )
        }
        let previous = Config.authMode
        Config.persistAuthMode(mode, acknowledged: body.acknowledged == true)
        let next = Config.authMode
        if previous != next {
            AuditService.log(
                action: "auth.mode_changed",
                resourceType: "settings",
                resourceName: next.rawValue,
                detail: "\(previous.rawValue)->\(next.rawValue)",
                req: req,
            )
        }
        return Self.snapshot()
    }

    static func snapshot() -> SecuritySettingsResponse {
        SecuritySettingsResponse(
            authMode: Config.authMode.rawValue,
            persistedAuthMode: Config.persistedAuthMode.rawValue,
            envLocked: Config.authModeEnvLocked,
        )
    }

    static func requireAdmin(_ req: Request) throws -> AuthenticatedUser {
        let user = try req.requireUser
        guard user.userRole == .admin else {
            throw BarkVisorError.forbidden("Admin only")
        }
        return user
    }
}
