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
}

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
        auth.grouped(loginRateLimit).post("login", use: login)
    }

    func bootProtected(routes: any RoutesBuilder) throws {
        routes.post("api", "auth", "ws-ticket", use: createWSTicket)
    }

    @Sendable
    func login(req: Vapor.Request) async throws -> LoginResponse {
        try LoginRequest.validate(content: req)
        let body = try req.content.decode(LoginRequest.self)

        do {
            let (token, user) = try await AuthService.login(
                username: body.username, password: body.password,
                hasher: BcryptHasher.shared, keys: keys, db: req.db,
            )
            AuditService.log(
                action: "auth.login", resourceType: "user", resourceId: user.id,
                resourceName: user.username, req: req,
            )
            return LoginResponse(token: token)
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
            targetVMID: body?.vmID,
        )
        return WSTicketResponse(ticket: ticket)
    }
}
