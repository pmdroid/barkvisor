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

    static func allows(mode: AuthMode, peerIP: String?) -> Bool {
        switch mode {
        case .secure:
            return false
        case .loopback:
            return AuthFrontDoorGuard.isLoopbackPeer(peerIP)
        case .disabled:
            return true
        }
    }

    static func allows(_ request: Request) -> Bool {
        allows(mode: Config.authMode, peerIP: peerIP(request))
    }

    static func pairingJoinAllowed(mode: AuthMode, peerIP: String?) -> Bool {
        if mode == .disabled {
            return AuthFrontDoorGuard.isLoopbackPeer(peerIP)
        }
        return true
    }

    static func pairingJoinAllowed(_ request: Request) -> Bool {
        pairingJoinAllowed(mode: Config.authMode, peerIP: peerIP(request))
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
