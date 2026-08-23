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
    let apiKeyKind: String?
    let role: String

    init(
        userId: String,
        username: String,
        authMethod: String,
        apiKeyId: String?,
        apiKeyKind: String? = nil,
        role: String,
    ) {
        self.userId = userId
        self.username = username
        self.authMethod = authMethod
        self.apiKeyId = apiKeyId
        self.apiKeyKind = apiKeyKind
        self.role = role
    }

    var userRole: UserRole {
        UserRolePolicy.parseStored(role)
    }
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
        // PAS-280: spend Device `?ticket=` only on owner-Device stream/SSE paths.
        switch StreamTicketPolicy.site(path: request.url.path) {
        case .homeTunnel:
            return try await authenticateHomeTunnel(request, chainingTo: next)
        case .ownerDevice:
            if let ticket = Self.deviceTicket(from: request) {
                return try await authenticateOwnerDeviceTicket(
                    request, ticket: ticket, chainingTo: next,
                )
            }
        case .ownerDeviceSSE:
            if let ticket = Self.deviceTicket(from: request) {
                return try await authenticateOwnerDeviceSSETicket(
                    request, ticket: ticket, chainingTo: next,
                )
            }
        case .other:
            break
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
            try await attach(
                authenticateAPIKey(token: token, request: request),
                to: request,
            )
            return try await next.respond(to: request)
        }

        // JWT auth (existing flow)
        try await attach(
            authenticateJWT(token: token, request: request),
            to: request,
        )
        return try await next.respond(to: request)
    }

    static func enforceInferenceACL(_ request: Vapor.Request) throws {
        guard let user = request.authenticatedUser else { return }
        let principal = OllamaAuthPolicy.principal(
            userRole: user.role,
            authMethod: user.authMethod,
            apiKeyKind: user.apiKeyKind,
        )
        guard !OllamaAuthPolicy.allows(
            principal: principal,
            method: request.method.rawValue,
            path: request.url.path,
        ) else { return }
        throw Abort(
            .forbidden,
            reason: "Inference callers can list models and call chat completions only",
        )
    }

    private func attach(_ user: AuthenticatedUser, to request: Vapor.Request) throws {
        request.authenticatedUser = user
        try Self.enforceInferenceACL(request)
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
            apiKeyKind: apiKey.kind,
            role: user.userRole.rawValue,
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

    private static func deviceTicket(from request: Vapor.Request) -> String? {
        StreamTicketPolicy.deviceTicket(fromQuery: request.url.query)
            ?? request.query[String.self, at: StreamTicketPolicy.ticketQueryName]
            ?? request.query[String.self, at: StreamTicketPolicy.tokenRewriteQueryName]
    }

    private func authenticateOwnerDeviceTicket(
        _ request: Vapor.Request,
        ticket: String,
        chainingTo next: any AsyncResponder,
    ) async throws -> Vapor.Response {
        guard let vmID = StreamTicketPolicy.ownerDeviceWorkloadID(request.url.path)
            ?? request.parameters.get("id")
            ?? request.parameters.get("vmId"),
            !vmID.isEmpty
        else {
            throw Abort(.unauthorized, reason: "Missing vm")
        }
        guard let userInfo = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: vmID)
        else {
            throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredTicketReason)
        }
        try await attach(
            ticketUser(
                userID: userInfo.userID, username: userInfo.username, request: request,
            ),
            to: request,
        )
        return try await next.respond(to: request)
    }

    private func authenticateOwnerDeviceSSETicket(
        _ request: Vapor.Request,
        ticket: String,
        chainingTo next: any AsyncResponder,
    ) async throws -> Vapor.Response {
        guard let userInfo = await WebSocketTicketStore.shared.validateTicket(ticket) else {
            throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredTicketReason)
        }
        try await attach(
            ticketUser(
                userID: userInfo.userID, username: userInfo.username, request: request,
            ),
            to: request,
        )
        return try await next.respond(to: request)
    }

    private func authenticateHomeTunnel(
        _ request: Vapor.Request,
        chainingTo next: any AsyncResponder,
    ) async throws -> Vapor.Response {
        if let auth = request.headers.bearerAuthorization {
            if auth.token.hasPrefix("barkvisor_") {
                try await attach(
                    authenticateAPIKey(token: auth.token, request: request),
                    to: request,
                )
            } else {
                try await attach(
                    authenticateJWT(token: auth.token, request: request),
                    to: request,
                )
            }
            return try await next.respond(to: request)
        }
        return try await HomeTunnelAuthMiddleware(keys: keys).respond(to: request, chainingTo: next)
    }

    private func authenticateJWT(token: String, request: Vapor.Request) async throws
        -> AuthenticatedUser {
        let payload: UserPayload
        do {
            payload = try await keys.verify(token, as: UserPayload.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        let role = try await Self.resolveRole(
            userId: payload.sub.value,
            sessionFallback: payload.role,
            request: request,
        )
        return AuthenticatedUser(
            userId: payload.sub.value,
            username: payload.username,
            authMethod: "jwt",
            apiKeyId: nil,
            role: role,
        )
    }

    private func ticketUser(userID: String, username: String, request: Vapor.Request) async throws
        -> AuthenticatedUser {
        let role = try await Self.resolveRole(
            userId: userID, sessionFallback: nil, request: request,
        )
        return AuthenticatedUser(
            userId: userID,
            username: username,
            authMethod: "ticket",
            apiKeyId: nil,
            role: role,
        )
    }

    static func resolveRole(
        userId: String,
        sessionFallback: String?,
        request: Vapor.Request,
    ) async throws -> String {
        guard let pool = request.application.databaseIfPresent?.pool else {
            return UserRolePolicy.parseSession(sessionFallback).rawValue
        }
        // Member Devices store the paired Home admin row. Home mints a
        // short-lived hop JWT over mTLS that can carry role=inference for that
        // same userId. Missing local rows still use the signed claim. When both
        // exist, take the tighter of the two so a hop cannot become admin.
        let user = try await pool.read { db in
            try User.fetchOne(db, key: userId)
        }
        let claim = sessionFallback.flatMap { $0.isEmpty ? nil : $0 }
        if let claim {
            let fromClaim = UserRolePolicy.parseSession(claim)
            guard let user else { return fromClaim.rawValue }
            return UserRolePolicy.moreRestrictive(fromClaim, user.userRole).rawValue
        }
        if let user {
            return user.userRole.rawValue
        }
        return UserRolePolicy.parseSession(nil).rawValue
    }
}

/// Home VNC/console tunnel: Bearer JWT or Home-minted `?session=` (PAS-237).
/// Device `?ticket=` / noVNC `?token=` are passed through unspent.
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
            let role = try await JWTAuthMiddleware.resolveRole(
                userId: payload.sub.value,
                sessionFallback: payload.role,
                request: request,
            )
            request.authenticatedUser = AuthenticatedUser(
                userId: payload.sub.value,
                username: payload.username,
                authMethod: "jwt",
                apiKeyId: nil,
                role: role,
            )
            try JWTAuthMiddleware.enforceInferenceACL(request)
            return try await next.respond(to: request)
        }
        let session = StreamTicketPolicy.homeSession(fromQuery: request.url.query)
            ?? request.query[String.self, at: StreamTicketPolicy.sessionQueryName]
        if let session, !session.isEmpty {
            guard let vmID = request.parameters.get("vmId"), !vmID.isEmpty else {
                throw Abort(.unauthorized, reason: "Missing vm")
            }
            guard let userInfo = await WebSocketTicketStore.shared.validateTicket(session, forVMID: vmID)
            else {
                throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredSessionReason)
            }
            let role = try await JWTAuthMiddleware.resolveRole(
                userId: userInfo.userID, sessionFallback: nil, request: request,
            )
            request.authenticatedUser = AuthenticatedUser(
                userId: userInfo.userID,
                username: userInfo.username,
                authMethod: "ticket",
                apiKeyId: nil,
                role: role,
            )
            try JWTAuthMiddleware.enforceInferenceACL(request)
            return try await next.respond(to: request)
        }
        throw Abort(.unauthorized, reason: "Missing authorization")
    }
}
