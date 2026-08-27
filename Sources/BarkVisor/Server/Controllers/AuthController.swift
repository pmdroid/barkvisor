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
    let role: String
}

struct AuthMeResponse: Content {
    let id: String
    let username: String
    let role: String
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

struct PasskeyLoginBeginRequest: Content {
    var username: String?
}

struct PasskeyRegisterBeginRequest: Content {
    var name: String?
}

extension PasskeyCredentialResponse: Content {}

struct AuthController: RouteCollection {
    let keys: JWTKeyCollection
    let loginRateLimit: RateLimitMiddleware

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")
        let limited = auth.grouped(loginRateLimit)
        limited.post("login", use: login)
        limited.post("refresh", use: refresh)
        limited.post("logout", use: logout)
        limited.post("login-offers", "redeem", use: redeemLoginOffer)
        let passkeyLogin = limited.grouped("passkeys", "login")
        passkeyLogin.post("begin", use: passkeyLoginBegin)
        passkeyLogin.post("finish", use: passkeyLoginFinish)
    }

    func bootProtected(routes: any RoutesBuilder) throws {
        routes.get("api", "auth", "me", use: me)
        routes.post("api", "auth", "ws-ticket", use: createWSTicket)
        let offers = routes.grouped("api", "auth", "login-offers")
        offers.post(use: issueLoginOffer)
        offers.get(use: currentLoginOffer)
        offers.delete(use: revokeLoginOffer)
        let passkeys = routes.grouped("api", "auth", "passkeys")
        passkeys.get(use: listPasskeys)
        passkeys.delete(":id", use: deletePasskey)
        passkeys.post("register", "begin", use: passkeyRegisterBegin)
        passkeys.post("register", "finish", use: passkeyRegisterFinish)
    }

    @Sendable
    func me(req: Vapor.Request) async throws -> AuthMeResponse {
        let authUser = try req.requireUser
        let user = try await req.db.read { db in
            try User.fetchOne(db, key: authUser.userId)
        }
        let role = user?.userRole ?? UserRolePolicy.parseStored(authUser.role)
        let username = user?.username ?? authUser.username
        return AuthMeResponse(id: authUser.userId, username: username, role: role.rawValue)
    }

    @Sendable
    func login(req: Vapor.Request) async throws -> LoginResponse {
        try LoginRequest.validate(content: req)
        let body = try req.content.decode(LoginRequest.self)

        do {
            let session = try await AuthService.loginSession(
                username: body.username, password: body.password,
                hasher: BcryptHasher.shared, keys: keys, db: req.db,
            )
            AuditService.log(
                action: "auth.login", resourceType: "user", resourceId: session.user.id,
                resourceName: session.user.username, req: req,
            )
            return LoginResponse(
                token: session.token,
                refreshToken: session.refreshToken,
                role: session.user.userRole.rawValue,
            )
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
            return LoginResponse(
                token: session.token,
                refreshToken: session.refreshToken,
                role: session.user.userRole.rawValue,
            )
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
            return LoginResponse(
                token: session.token,
                refreshToken: session.refreshToken,
                role: session.user.userRole.rawValue,
            )
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
    func listPasskeys(req: Vapor.Request) async throws -> [PasskeyCredentialResponse] {
        let authUser = try requirePasskeySession(req)
        return try await PasskeyService.list(userId: authUser.userId, db: req.db)
    }

    @Sendable
    func deletePasskey(req: Vapor.Request) async throws -> HTTPStatus {
        let authUser = try requirePasskeySession(req)
        guard let id = req.parameters.get("id"), !id.isEmpty else {
            throw BarkVisorError.badRequest("Missing passkey id")
        }
        do {
            try await PasskeyService.delete(id: id, userId: authUser.userId, db: req.db)
            AuditService.log(
                action: "auth.passkey.delete", resourceType: "passkey", resourceId: id, req: req,
            )
            return .noContent
        } catch {
            if let bvError = error as? BarkVisorError, bvError.httpStatus == 401 {
                AuditService.log(action: "auth.passkey.delete.failed", req: req)
            }
            throw error
        }
    }

    @Sendable
    func passkeyRegisterBegin(req: Vapor.Request) async throws -> Response {
        let authUser = try requirePasskeySession(req)
        let body = (try? req.content.decode(PasskeyRegisterBeginRequest.self)) ?? PasskeyRegisterBeginRequest()
        let user = try await req.db.read { db in
            try User.fetchOne(db, key: authUser.userId)
        }
        guard let user else {
            throw BarkVisorError.unauthorized()
        }
        let rp = try passkeyRelyingParty(req)
        let begin = try await PasskeyService.beginRegister(
            user: user, name: body.name, rp: rp, db: req.db,
        )
        return try passkeyJSON(begin)
    }

    @Sendable
    func passkeyRegisterFinish(req: Vapor.Request) async throws -> PasskeyCredentialResponse {
        let authUser = try requirePasskeySession(req)
        let raw = try await req.body.collect(upTo: 1 << 20)
        let data = Data(buffer: raw)
        let envelope = try passkeyFinishEnvelope(data)
        let rp = try passkeyRelyingParty(req)
        do {
            let row = try await PasskeyService.finishRegister(
                sessionId: envelope.sessionId,
                credentialJSON: credentialJSON(from: envelope.object),
                name: envelope.name,
                userId: authUser.userId,
                rp: rp,
                db: req.db,
            )
            AuditService.log(
                action: "auth.passkey.register", resourceType: "passkey", resourceId: row.id,
                resourceName: row.name, req: req,
            )
            return row
        } catch {
            if let bvError = error as? BarkVisorError, bvError.httpStatus == 401 {
                AuditService.log(action: "auth.passkey.register.failed", req: req)
            }
            throw error
        }
    }

    @Sendable
    func passkeyLoginBegin(req: Vapor.Request) async throws -> Response {
        _ = try? req.content.decode(PasskeyLoginBeginRequest.self)
        let rp = try passkeyRelyingParty(req)
        let begin = try await PasskeyService.beginLogin(rp: rp)
        return try passkeyJSON(begin)
    }

    @Sendable
    func passkeyLoginFinish(req: Vapor.Request) async throws -> LoginResponse {
        let raw = try await req.body.collect(upTo: 1 << 20)
        let data = Data(buffer: raw)
        let envelope = try passkeyFinishEnvelope(data)
        let rp = try passkeyRelyingParty(req)
        do {
            let session = try await PasskeyService.finishLogin(
                sessionId: envelope.sessionId,
                credentialJSON: credentialJSON(from: envelope.object),
                rp: rp,
                keys: keys,
                db: req.db,
            )
            AuditService.log(
                action: "auth.passkey.login", resourceType: "user", resourceId: session.user.id,
                resourceName: session.user.username, req: req,
            )
            return LoginResponse(
                token: session.token,
                refreshToken: session.refreshToken,
                role: session.user.userRole.rawValue,
            )
        } catch {
            if let bvError = error as? BarkVisorError, bvError.httpStatus == 401 {
                AuditService.log(action: "auth.passkey.login.failed", req: req)
            }
            throw error
        }
    }

    private func requirePasskeySession(_ req: Vapor.Request) throws -> AuthenticatedUser {
        let authUser = try req.requireUser
        guard authUser.authMethod == "jwt" else {
            throw BarkVisorError.forbidden("Passkeys require a signed-in session")
        }
        return authUser
    }

    private func passkeyRelyingParty(_ req: Vapor.Request) throws -> PasskeyRelyingParty {
        try PasskeyService.relyingParty(
            hostHeader: req.headers[.host].first,
            originHeader: req.headers[.origin].first,
        )
    }

    private func passkeyJSON(_ begin: PasskeyCeremonyBegin) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return try Response(status: .ok, headers: headers, body: .init(data: begin.responseBody()))
    }

    private func passkeyFinishEnvelope(_ data: Data) throws -> (sessionId: String, name: String?, object: [String: Any]) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              !sessionId.isEmpty
        else {
            throw BarkVisorError.badRequest("Invalid passkey credential")
        }
        return (sessionId, obj["name"] as? String, obj)
    }

    private func credentialJSON(from object: [String: Any]) throws -> Data {
        guard let credential = object["credential"] else {
            throw BarkVisorError.badRequest("Invalid passkey credential")
        }
        guard JSONSerialization.isValidJSONObject(credential) else {
            throw BarkVisorError.badRequest("Invalid passkey credential")
        }
        return try JSONSerialization.data(withJSONObject: credential)
    }
}
