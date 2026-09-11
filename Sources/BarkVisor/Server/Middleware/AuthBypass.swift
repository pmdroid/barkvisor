import BarkVisorCore
import Foundation
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

    static func attachIfAllowed(_ request: Request) async throws -> Bool {
        guard allows(request) else { return false }
        switch await frontDoorDecision(for: request) {
        case .allow:
            request.authenticatedUser = syntheticAdmin
            return true
        case .rejectHost:
            if hasOwnCredentials(request) { return false }
            throw Abort(.forbidden, reason: "Invalid Host")
        case .rejectOrigin:
            if hasOwnCredentials(request) { return false }
            throw Abort(.forbidden, reason: "Invalid Origin")
        }
    }

    static func frontDoorOK(_ request: Request) async -> Bool {
        await frontDoorDecision(for: request) == .allow
    }

    static func frontDoorDecision(for request: Request) async -> AuthFrontDoorDecision {
        let host = request.headers[.host].first
        let origin = request.headers[.origin].first
        let method = request.method.rawValue
        if AuthFrontDoorGuard.evaluate(
            host: host,
            origin: origin,
            method: method,
            extras: AuthFrontDoorGuard.configuredHosts(),
        ) == .allow {
            return .allow
        }
        var extras = AuthFrontDoorGuard.configuredHosts()
        if let database = request.application.databaseIfPresent,
           let deviceUrl = try? await database.pool.read({ db in
               try RemoteAccessSettings.load(from: db).deviceUrl
           }) {
            extras.formUnion(AuthFrontDoorGuard.advertisedHosts(from: deviceUrl))
        }
        return AuthFrontDoorGuard.evaluate(
            host: host,
            origin: origin,
            method: method,
            extras: extras,
        )
    }

    static func hasOwnCredentials(_ request: Request) -> Bool {
        if !request.headers["Authorization"].isEmpty {
            return true
        }
        if !request.headers["Cookie"].isEmpty {
            return true
        }
        let ticketNames = [StreamTicketPolicy.ticketQueryName, StreamTicketPolicy.tokenRewriteQueryName]
        return ticketNames.contains { name in
            request.query[String.self, at: name] != nil
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
        FileHandle.standardError.write(Data("*** \(line)\n".utf8))
    }
}
