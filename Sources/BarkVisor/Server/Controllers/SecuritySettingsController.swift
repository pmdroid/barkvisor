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

enum SecuritySettingsPolicy {
    static func validatedMode(
        raw: String,
        acknowledged: Bool?,
        envLocked: Bool,
        hasProvisionedAdmin: Bool,
    ) throws -> AuthMode {
        if envLocked {
            throw BarkVisorError.conflict("authMode is locked by \(AuthModeStore.envKey)")
        }
        guard let mode = AuthModeStore.parse(raw) else {
            throw BarkVisorError.badRequest("authMode must be secure, loopback, or disabled")
        }
        if mode == .disabled, acknowledged != true {
            throw BarkVisorError.badRequest(
                "Disabling sign-in for the whole network requires acknowledged=true",
            )
        }
        if mode == .secure, !hasProvisionedAdmin {
            throw BarkVisorError.preconditionFailed(
                "Create an admin account before requiring sign-in",
            )
        }
        return mode
    }
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
        let hasAdmin = try await req.db.read { db in
            try User.hasProvisionedAdmin(db)
        }
        let mode = try SecuritySettingsPolicy.validatedMode(
            raw: body.authMode,
            acknowledged: body.acknowledged,
            envLocked: Config.authModeEnvLocked,
            hasProvisionedAdmin: hasAdmin,
        )
        let previous = Config.authMode
        Config.persistAuthMode(mode, acknowledged: body.acknowledged == true)
        let next = Config.authMode
        if previous != next {
            AuditService.log(
                action: "auth.mode_changed",
                resourceType: "settings",
                resourceName: next.rawValue,
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
