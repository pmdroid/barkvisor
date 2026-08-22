import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

struct LoginRequest: Content, Validatable {
    let username: String
    let password: String

    static func validations(_ validations: inout Validations) {
        validations.add("username", as: String.self, is: !.empty)
        validations.add("password", as: String.self, is: !.empty)
    }
}

struct LoginResponse: Content {
    let token: String
    let refreshToken: String
}

struct LoginChallengeResponse: Content {
    let totpRequired: Bool
    let challengeToken: String
    let challengeExpiresAt: String
}

struct LoginChallengeRequest: Content, Validatable {
    let challengeToken: String
    let code: String

    static func validations(_ validations: inout Validations) {
        validations.add("challengeToken", as: String.self, is: !.empty)
        validations.add("code", as: String.self, is: !.empty)
    }
}

struct TOTPCodeRequest: Content, Validatable {
    let code: String

    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty)
    }
}

struct TOTPDisableRequest: Content, Validatable {
    let password: String
    let code: String

    static func validations(_ validations: inout Validations) {
        validations.add("password", as: String.self, is: !.empty)
        validations.add("code", as: String.self, is: !.empty)
    }
}

struct RefreshRequest: Content, Validatable {
    let refreshToken: String

    static func validations(_ validations: inout Validations) {
        validations.add("refreshToken", as: String.self, is: !.empty)
    }
}

struct LogoutRequest: Content {
    var refreshToken: String?
}

struct LoginOfferIssueRequest: Content {
    var advertisedHost: String?
}

struct LoginRedeemRequest: Content, Validatable {
    let code: String

    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty)
    }
}

extension LoginOfferIssue: Content {}

struct WSTicketRequest: Content {
    let vmID: String?
}

struct WSTicketResponse: Content {
    let ticket: String
}

struct AuthController: RouteCollection {
    let keys: JWTKeyCollection
    let loginRateLimit: RateLimitMiddleware

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")
        let limited = auth.grouped(loginRateLimit)
        limited.post("login", use: login)
        limited.post("login", "challenge", use: completeLoginChallenge)
        limited.post("refresh", use: refresh)
        limited.post("logout", use: logout)
        limited.post("login-offers", "redeem", use: redeemLoginOffer)
    }

    func bootProtected(routes: any RoutesBuilder) throws {
        routes.post("api", "auth", "ws-ticket", use: createWSTicket)
        let offers = routes.grouped("api", "auth", "login-offers")
        offers.post(use: issueLoginOffer)
        offers.get(use: currentLoginOffer)
        offers.delete(use: revokeLoginOffer)

        let totp = routes.grouped("api", "auth", "totp")
        totp.get(use: totpStatus)
        totp.post("setup", use: totpSetup)
        totp.post("confirm", use: totpConfirm)
        totp.post("disable", use: totpDisable)
        totp.post("recovery-codes", use: totpRegenerateRecoveryCodes)
    }

    @Sendable
    func login(req: Vapor.Request) async throws -> Response {
        try LoginRequest.validate(content: req)
        let body = try req.content.decode(LoginRequest.self)

        do {
            let result = try await AuthService.passwordLogin(
                username: body.username, password: body.password,
                hasher: BcryptHasher.shared, keys: keys, db: req.db,
            )
            switch result {
            case let .session(session):
                AuditService.log(
                    action: "auth.login", resourceType: "user", resourceId: session.user.id,
                    resourceName: session.user.username, req: req,
                )
                return try await LoginResponse(token: session.token, refreshToken: session.refreshToken)
                    .encodeResponse(for: req)
            case let .totpChallenge(challenge):
                AuditService.log(action: "auth.login.totp_required", resourceType: "user", req: req)
                return try await LoginChallengeResponse(
                    totpRequired: true,
                    challengeToken: challenge.challengeToken,
                    challengeExpiresAt: challenge.expiresAt,
                ).encodeResponse(status: .accepted, for: req)
            }
        } catch {
            // Log failed attempts without exposing the submitted username (could be a mistyped password)
            if let bvError = error as? BarkVisorError {
                if bvError.httpStatus == 401 {
                    AuditService.log(
                        action: "auth.login.failed", detail: "Invalid credentials", req: req,
                    )
                } else if bvError.httpStatus == 403 {
                    AuditService.log(
                        action: "auth.login.failed", detail: "Account not yet configured", req: req,
                    )
                }
            }
            throw error
        }
    }

    @Sendable
    func completeLoginChallenge(req: Vapor.Request) async throws -> LoginResponse {
        try LoginChallengeRequest.validate(content: req)
        let body = try req.content.decode(LoginChallengeRequest.self)
        do {
            let session = try await AuthService.completeLoginChallenge(
                challengeToken: body.challengeToken, code: body.code, keys: keys, db: req.db,
            )
            AuditService.log(
                action: "auth.login", resourceType: "user", resourceId: session.user.id,
                resourceName: session.user.username, req: req,
            )
            return LoginResponse(token: session.token, refreshToken: session.refreshToken)
        } catch {
            AuditService.log(action: "auth.login.failed", detail: "Invalid authenticator code", req: req)
            throw error
        }
    }

    @Sendable
    func refresh(req: Vapor.Request) async throws -> LoginResponse {
        try RefreshRequest.validate(content: req)
        let body = try req.content.decode(RefreshRequest.self)
        do {
            let session = try await AuthService.refresh(
                refreshToken: body.refreshToken, keys: keys, db: req.db,
            )
            AuditService.log(
                action: "auth.refresh", resourceType: "user", resourceId: session.user.id,
                resourceName: session.user.username, req: req,
            )
            return LoginResponse(token: session.token, refreshToken: session.refreshToken)
        } catch {
            AuditService.log(action: "auth.refresh.failed", detail: "Invalid refresh token", req: req)
            throw error
        }
    }

    @Sendable
    func logout(req: Vapor.Request) async throws -> HTTPStatus {
        let body = try? req.content.decode(LogoutRequest.self)
        guard let refreshToken = body?.refreshToken, !refreshToken.isEmpty else {
            throw BarkVisorError.unauthorized("Missing refresh token")
        }
        // Bearer authenticates/audits only. Do not revoke every family for this user.
        if let bearer = req.headers.bearerAuthorization?.token,
           let payload = try? await keys.verify(bearer, as: UserPayload.self) {
            AuditService.log(
                action: "auth.logout", resourceType: "user", resourceId: payload.sub.value,
                resourceName: payload.username, req: req,
            )
        } else {
            AuditService.log(action: "auth.logout", resourceType: "user", req: req)
        }
        try await AuthService.revokeRefreshToken(refreshToken, db: req.db)
        return .noContent
    }

    @Sendable
    func issueLoginOffer(req: Vapor.Request) async throws -> LoginOfferIssue {
        let authUser = try req.requireUser
        let advertised = (try? req.content.decode(LoginOfferIssueRequest.self))?.advertisedHost
        let advertiseUrl = try await req.db.read { db in
            try RemoteAccessSettings.load(from: db).advertiseUrl
        }
        let hosts = RemoteAccessSettings.advertisedHosts(advertiseUrl: advertiseUrl)
        let offer = try await LoginOfferService.issue(
            LoginOfferService.IssueInput(
                userId: authUser.userId,
                advertisedHost: advertised,
                advertisedHosts: hosts,
            ),
            db: req.db,
        )
        AuditService.log(
            action: "auth.login_offer.issue", resourceType: "user", resourceId: authUser.userId,
            resourceName: authUser.username, req: req,
        )
        return offer
    }

    @Sendable
    func currentLoginOffer(req: Vapor.Request) async throws -> LoginOfferIssue {
        _ = try req.requireUser
        return try await LoginOfferService.current(db: req.db)
    }

    @Sendable
    func revokeLoginOffer(req: Vapor.Request) async throws -> HTTPStatus {
        _ = try req.requireUser
        try await LoginOfferService.revoke(db: req.db)
        AuditService.log(action: "auth.login_offer.revoke", resourceType: "user", req: req)
        return .noContent
    }

    @Sendable
    func redeemLoginOffer(req: Vapor.Request) async throws -> LoginResponse {
        try LoginRedeemRequest.validate(content: req)
        let body = try req.content.decode(LoginRedeemRequest.self)
        do {
            let session = try await LoginOfferService.redeem(
                code: body.code, keys: keys, db: req.db,
            )
            AuditService.log(
                action: "auth.login_offer.redeem", resourceType: "user",
                resourceId: session.user.id, resourceName: session.user.username, req: req,
            )
            return LoginResponse(token: session.token, refreshToken: session.refreshToken)
        } catch {
            AuditService.log(
                action: "auth.login_offer.redeem.failed", detail: "Invalid sign-in code", req: req,
            )
            throw error
        }
    }

    @Sendable
    func createWSTicket(req: Vapor.Request) async throws -> WSTicketResponse {
        let authUser = try req.requireUser
        let body: WSTicketRequest? =
            if req.headers.contentType == .json {
                try req.content.decode(WSTicketRequest.self)
            } else {
                nil
            }
        let ticket = await WebSocketTicketStore.shared.createTicket(
            forUserID: authUser.userId, username: authUser.username,
            targetVMID: body?.vmID.flatMap { $0.isEmpty ? nil : $0 },
        )
        return WSTicketResponse(ticket: ticket)
    }

    @Sendable
    func totpStatus(req: Vapor.Request) async throws -> TOTPStatus {
        let authUser = try requirePasswordSession(req)
        return try await TOTPService.status(userId: authUser.userId, db: req.db)
    }

    @Sendable
    func totpSetup(req: Vapor.Request) async throws -> TOTPSetup {
        let authUser = try requirePasswordSession(req)
        let setup = try await TOTPService.beginSetup(
            userId: authUser.userId, username: authUser.username, db: req.db,
        )
        AuditService.log(
            action: "auth.totp.setup", resourceType: "user", resourceId: authUser.userId,
            resourceName: authUser.username, req: req,
        )
        return setup
    }

    @Sendable
    func totpConfirm(req: Vapor.Request) async throws -> TOTPRecoveryCodes {
        let authUser = try requirePasswordSession(req)
        try TOTPCodeRequest.validate(content: req)
        let body = try req.content.decode(TOTPCodeRequest.self)
        let codes = try await TOTPService.confirmSetup(
            userId: authUser.userId, code: body.code, db: req.db,
        )
        AuditService.log(
            action: "auth.totp.enable", resourceType: "user", resourceId: authUser.userId,
            resourceName: authUser.username, req: req,
        )
        return codes
    }

    @Sendable
    func totpDisable(req: Vapor.Request) async throws -> HTTPStatus {
        let authUser = try requirePasswordSession(req)
        try TOTPDisableRequest.validate(content: req)
        let body = try req.content.decode(TOTPDisableRequest.self)
        _ = try await AuthService.authenticatePassword(
            username: authUser.username, password: body.password,
            hasher: BcryptHasher.shared, db: req.db,
        )
        try await TOTPService.disable(userId: authUser.userId, code: body.code, db: req.db)
        AuditService.log(
            action: "auth.totp.disable", resourceType: "user", resourceId: authUser.userId,
            resourceName: authUser.username, req: req,
        )
        return .noContent
    }

    @Sendable
    func totpRegenerateRecoveryCodes(req: Vapor.Request) async throws -> TOTPRecoveryCodes {
        let authUser = try requirePasswordSession(req)
        try TOTPCodeRequest.validate(content: req)
        let body = try req.content.decode(TOTPCodeRequest.self)
        let codes = try await TOTPService.regenerateRecoveryCodes(
            userId: authUser.userId, code: body.code, db: req.db,
        )
        AuditService.log(
            action: "auth.totp.recovery_codes", resourceType: "user", resourceId: authUser.userId,
            resourceName: authUser.username, req: req,
        )
        return codes
    }

    private func requirePasswordSession(_ req: Vapor.Request) throws -> AuthenticatedUser {
        let user = try req.requireUser
        guard user.authMethod == "jwt" else {
            throw BarkVisorError.forbidden("Two-factor settings require a signed-in password session")
        }
        return user
    }
}
