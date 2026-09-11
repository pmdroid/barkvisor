import BarkVisorCore
import Vapor

enum AuthBypass {
    static let syntheticUserId = "local-bypass"
    static let syntheticUsername = "local"
    static let syntheticAuthMethod = "bypass"

    static var syntheticAdmin: AuthenticatedUser {
        AuthenticatedUser(
            userId: syntheticUserId,
            username: syntheticUsername,
            authMethod: syntheticAuthMethod,
            apiKeyId: nil,
            role: UserRole.admin.rawValue,
        )
    }

    static func peerIP(_ request: Request) -> String? {
        request.remoteAddress?.ipAddress ?? request.peerAddress?.ipAddress
    }

    static func isProxied(_ request: Request) -> Bool {
        let headers = request.headers
        return !headers["X-Forwarded-For"].isEmpty
            || !headers["X-Real-IP"].isEmpty
            || !headers["Forwarded"].isEmpty
    }

    static func allows(mode: AuthMode, peerIP: String?, proxied: Bool = false) -> Bool {
        switch mode {
        case .secure:
            return false
        case .loopback:
            return !proxied && AuthFrontDoorGuard.isLoopbackPeer(peerIP)
        case .disabled:
            return true
        }
    }

    static func allows(_ request: Request) -> Bool {
        allows(mode: Config.authMode, peerIP: peerIP(request), proxied: isProxied(request))
    }

    static func pairingJoinAllowed(mode: AuthMode, peerIP: String?, proxied: Bool = false) -> Bool {
        if mode == .disabled {
            return !proxied && AuthFrontDoorGuard.isLoopbackPeer(peerIP)
        }
        return true
    }

    static func pairingJoinAllowed(_ request: Request) -> Bool {
        pairingJoinAllowed(
            mode: Config.authMode,
            peerIP: peerIP(request),
            proxied: isProxied(request),
        )
    }

    static func validateSyntheticSubject(_ subject: String, request: Request) throws {
        guard subject == syntheticUserId else { return }
        guard allows(request) else {
            throw Abort(.unauthorized, reason: "Bypass session is only valid where sign-in is skipped")
        }
    }

    static func attachIfAllowed(_ request: Request) throws -> Bool {
        guard allows(request) else { return false }
        try validateFrontDoor(request)
        request.authenticatedUser = syntheticAdmin
        return true
    }

    static func validateFrontDoor(_ request: Request) throws {
        switch AuthFrontDoorGuard.evaluate(
            host: request.headers[.host].first,
            origin: request.headers[.origin].first,
            method: request.method.rawValue,
            extras: AuthFrontDoorGuard.configuredHosts(),
        ) {
        case .allow:
            return
        case .rejectHost:
            throw Abort(.forbidden, reason: "Invalid Host")
        case .rejectOrigin:
            throw Abort(.forbidden, reason: "Invalid Origin")
        }
    }
}

struct RejectPasskeysWhenBypassedMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response {
        if AuthBypass.allows(request) {
            throw Abort(.notFound)
        }
        return try await next.respond(to: request)
    }
}

enum AuthModeStartup {
    static func announce(mode: AuthMode) {
        guard mode != .secure else { return }
        let line =
            "BarkVisor sign-in is \(mode.rawValue). The HTTP server binds 0.0.0.0. Re-enable sign-in in Settings or unset \(AuthModeStore.envKey)."
        Log.auth.warning(line)
        fputs("*** \(line)\n", stderr)
    }
}
