import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

// Bcrypt is used only for backward-compatible verification of legacy API key hashes.

// UserPayload moved to BarkVisorCore

struct AuthenticatedUser {
    let userId: String
    let username: String
    let authMethod: String // "jwt", "apikey", or "ticket"
    let apiKeyId: String? // set when authMethod == "apikey"
}

struct AuthenticatedUserKey: StorageKey {
    typealias Value = AuthenticatedUser
}

extension Vapor.Request {
    var authenticatedUser: AuthenticatedUser? {
        get { storage[AuthenticatedUserKey.self] }
        set { storage[AuthenticatedUserKey.self] = newValue }
    }

    /// Returns the authenticated user. Only call on routes behind `JWTAuthMiddleware`.
    /// Throws `.unauthorized` if no user is set (should never happen behind the middleware).
    var requireUser: AuthenticatedUser {
        get throws {
            guard let user = authenticatedUser else {
                throw Abort(.unauthorized)
            }
            return user
        }
    }
}

struct JWTAuthMiddleware: AsyncMiddleware {
    let keys: JWTKeyCollection

    func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
        -> Vapor.Response {
        // Home console/VNC: Device `?ticket=` is forwarded. Auth is Bearer or
        // Home-minted `?session=` — never spend the Device ticket here.
        if Self.isHomeConsoleTunnel(request) {
            return try await authenticateHomeTunnel(request, chainingTo: next)
        }

        // Accept ticket from ?ticket= query param (short-lived, single-use)
        if let ticketParam = request.query[String.self, at: "ticket"] {
            if let userInfo = await WebSocketTicketStore.shared.validateTicket(ticketParam) {
                request.authenticatedUser = AuthenticatedUser(
                    userId: userInfo.userID,
                    username: userInfo.username,
                    authMethod: "ticket",
                    apiKeyId: nil,
                )
                return try await next.respond(to: request)
            }
            throw Abort(.unauthorized, reason: "Invalid or expired ticket")
        }

        // Accept token from Bearer header only (query param removed to prevent token leakage in logs/history)
        let token: String
        if let authHeader = request.headers.bearerAuthorization {
            token = authHeader.token
        } else {
            throw Abort(.unauthorized, reason: "Missing authorization header")
        }

        // API key auth: tokens starting with "barkvisor_"
        if token.hasPrefix("barkvisor_") {
            request.authenticatedUser = try await authenticateAPIKey(token: token, request: request)
            return try await next.respond(to: request)
        }

        // JWT auth (existing flow)
        request.authenticatedUser = try await authenticateJWT(token: token)

        return try await next.respond(to: request)
    }

    private func authenticateAPIKey(token: String, request: Vapor.Request) async throws
        -> AuthenticatedUser {
        let prefix = String(token.prefix(15))

        // Fast path: compute HMAC-SHA256 hash and do a direct DB lookup
        let hmacHex = APIKeyService.hmacHash(token)
        var apiKey: APIKey? = try await request.db.read { db in
            try APIKey
                .filter(APIKey.Columns.keyHash == hmacHex)
                .filter(APIKey.Columns.keyPrefix == prefix)
                .fetchOne(db)
        }

        // Backward compatibility: fall back to bcrypt verification for legacy keys
        if apiKey == nil {
            apiKey = try await findAndUpgradeLegacyKey(
                token: token, prefix: prefix, hmacHex: hmacHex, request: request,
            )
        }

        guard let apiKey else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }

        if apiKey.isExpired {
            throw Abort(.unauthorized, reason: "API key has expired")
        }

        // Load user
        let user = try await request.db.read { db in
            try User.fetchOne(db, key: apiKey.userId)
        }
        guard let user else {
            throw Abort(.unauthorized, reason: "API key owner not found")
        }

        // Update lastUsedAt
        let now = iso8601.string(from: Date())
        do {
            try await request.db.write { db in
                try db.execute(
                    sql: "UPDATE api_keys SET lastUsedAt = ? WHERE id = ?",
                    arguments: [now, apiKey.id],
                )
            }
        } catch {
            Log.auth.error(
                "Failed to update lastUsedAt for API key \(apiKey.id): \(error.localizedDescription)",
            )
        }

        return AuthenticatedUser(
            userId: user.id,
            username: user.username,
            authMethod: "apikey",
            apiKeyId: apiKey.id,
        )
    }

    private func findAndUpgradeLegacyKey(
        token: String, prefix: String, hmacHex: String, request: Vapor.Request,
    ) async throws -> APIKey? {
        let candidates = try await request.db.read { db in
            try APIKey
                .filter(APIKey.Columns.keyPrefix == prefix)
                .limit(5)
                .fetchAll(db)
        }
        let legacyMatch =
            try candidates
                .first(where: { try APIKeyService.isBcryptHash($0.keyHash) && Bcrypt.verify(token, created: $0.keyHash) })

        guard let matched = legacyMatch else {
            return nil
        }

        Log.auth.warning(
            "API key \(matched.id) uses legacy bcrypt hash — re-hashing with HMAC-SHA256. "
                + "Revoke and re-create the key to silence this warning.",
        )
        // Upgrade the stored hash to HMAC-SHA256
        do {
            try await request.db.write { db in
                try db.execute(
                    sql: "UPDATE api_keys SET keyHash = ? WHERE id = ?",
                    arguments: [hmacHex, matched.id],
                )
            }
        } catch {
            Log.auth.error(
                "Failed to upgrade API key hash for \(matched.id): \(error.localizedDescription)",
            )
        }
        return matched
    }

    private static func isHomeConsoleTunnel(_ request: Vapor.Request) -> Bool {
        let path = request.url.path
        guard path.contains("/api/home/devices/") else { return false }
        return path.hasSuffix("/vnc") || path.hasSuffix("/console")
    }

    private func authenticateHomeTunnel(
        _ request: Vapor.Request,
        chainingTo next: any AsyncResponder,
    ) async throws -> Vapor.Response {
        if let auth = request.headers.bearerAuthorization {
            if auth.token.hasPrefix("barkvisor_") {
                request.authenticatedUser = try await authenticateAPIKey(
                    token: auth.token,
                    request: request,
                )
            } else {
                request.authenticatedUser = try await authenticateJWT(token: auth.token)
            }
            return try await next.respond(to: request)
        }
        return try await HomeTunnelAuthMiddleware(keys: keys).respond(to: request, chainingTo: next)
    }

    private func authenticateJWT(token: String) async throws -> AuthenticatedUser {
        let payload: UserPayload
        do {
            payload = try await keys.verify(token, as: UserPayload.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        return AuthenticatedUser(
            userId: payload.sub.value,
            username: payload.username,
            authMethod: "jwt",
            apiKeyId: nil,
        )
    }
}

/// Home VNC/console tunnel: Bearer JWT or a Home-minted `?session=` ticket
/// scoped to `:vmId`. Does **not** consume `?ticket=` / `?token=` — those are
/// the Device ticket (noVNC rewrites `ticket` to `token`). Browser WebSockets
/// cannot set `Authorization`, so the SPA exchanges the JWT for `session=`.
struct HomeTunnelAuthMiddleware: AsyncMiddleware {
    let keys: JWTKeyCollection

    func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
        -> Vapor.Response {
        if let auth = request.headers.bearerAuthorization {
            let payload: UserPayload
            do {
                payload = try await keys.verify(auth.token, as: UserPayload.self)
            } catch {
                throw Abort(.unauthorized, reason: "Invalid or expired token")
            }
            request.authenticatedUser = AuthenticatedUser(
                userId: payload.sub.value,
                username: payload.username,
                authMethod: "jwt",
                apiKeyId: nil,
            )
            return try await next.respond(to: request)
        }
        if let session = request.query[String.self, at: "session"], !session.isEmpty {
            guard let vmID = request.parameters.get("vmId"), !vmID.isEmpty else {
                throw Abort(.unauthorized, reason: "Missing vm")
            }
            guard let userInfo = await WebSocketTicketStore.shared.validateTicket(session, forVMID: vmID)
            else {
                throw Abort(.unauthorized, reason: "Invalid or expired session")
            }
            request.authenticatedUser = AuthenticatedUser(
                userId: userInfo.userID,
                username: userInfo.username,
                authMethod: "ticket",
                apiKeyId: nil,
            )
            return try await next.respond(to: request)
        }
        throw Abort(.unauthorized, reason: "Missing authorization")
    }
}
