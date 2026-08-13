import BarkVisorCore
import Foundation
import Vapor

extension PairingIssueResponse: Content {}
extension PairingRedeemRequest: Content {}
extension PairingRedeemResponse: Content {}
extension PairingJoinRequest: Content {}
extension PairingJoinResponse: Content {}

/// Pairing issue / redeem (PAS-45). JWT on the issuer; redeem is public
/// and rate-limited. Join is public only until setup completes.
struct PairingController: RouteCollection {
    let offers: PairingOfferStore
    let setupMiddleware: SetupMiddleware
    let jwt: JWTAuthMiddleware
    let rateLimit: RateLimitMiddleware

    func boot(routes: any RoutesBuilder) throws {
        let pairing = routes.grouped("api", "pairing")
        pairing.grouped(rateLimit).post("redeem", use: redeem)
        pairing.grouped(SetupOrJWTMiddleware(setup: setupMiddleware, jwt: jwt), rateLimit)
            .post("join", use: join)
    }

    func bootProtected(routes: any RoutesBuilder) throws {
        let pairing = routes.grouped("api", "pairing")
        pairing.post("codes", use: issue)
        pairing.get("codes", use: current)
        pairing.delete("codes", use: revoke)
    }

    struct IssueRequest: Content {
        var advertisedHost: String?
    }

    @Sendable
    func issue(req: Vapor.Request) async throws -> PairingIssueResponse {
        _ = try req.requireUser
        let advertised = (try? req.content.decode(IssueRequest.self))?.advertisedHost
        do {
            let response = try PairingService.issue(
                PairingService.IssueInput(
                    dataDir: Config.dataDir,
                    hostId: Config.hostId,
                    advertisedHost: advertised,
                ),
                offers: offers,
            )
            AuditService.log(
                action: "pairing.issue",
                resourceType: "device",
                resourceId: response.hostId,
                req: req,
            )
            return response
        } catch let error as PairingError {
            throw map(error)
        }
    }

    @Sendable
    func current(req: Vapor.Request) async throws -> PairingIssueResponse {
        _ = try req.requireUser
        do {
            return try PairingService.currentOffer(
                PairingService.IssueInput(
                    dataDir: Config.dataDir,
                    hostId: Config.hostId,
                ),
                offers: offers,
            )
        } catch let error as PairingError {
            throw map(error)
        }
    }

    @Sendable
    func revoke(req: Vapor.Request) async throws -> HTTPStatus {
        _ = try req.requireUser
        do {
            try PairingService.revoke(dataDir: Config.dataDir, offers: offers)
            AuditService.log(action: "pairing.revoke", resourceType: "device", req: req)
            return .noContent
        } catch let error as PairingError {
            throw map(error)
        }
    }

    @Sendable
    func redeem(req: Vapor.Request) async throws -> PairingRedeemResponse {
        let body: PairingRedeemRequest
        do {
            body = try req.content.decode(PairingRedeemRequest.self)
        } catch {
            throw BarkVisorError.badRequest("Invalid pairing redeem request")
        }
        do {
            let response = try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: Config.dataDir,
                    issuerHostId: Config.hostId,
                    request: body,
                ),
                offers: offers,
            )
            AuditService.log(
                action: "pairing.redeem",
                resourceType: "device",
                resourceId: body.hostId,
                req: req,
            )
            return response
        } catch let error as PairingError {
            if case .expiredOrUsed = error {
                AuditService.log(
                    action: "pairing.redeem.failed",
                    resourceType: "device",
                    detail: "invalid_or_expired",
                    req: req,
                )
            }
            throw map(error)
        }
    }

    @Sendable
    func join(req: Vapor.Request) async throws -> PairingJoinResponse {
        let body: PairingJoinRequest
        do {
            body = try req.content.decode(PairingJoinRequest.self)
        } catch {
            throw BarkVisorError.badRequest("Invalid pairing join request")
        }
        do {
            let response = try await PairingService.join(
                request: body,
                dataDir: Config.dataDir,
                hostId: Config.hostId,
                client: URLSessionPairingHTTPClient(),
            )
            AuditService.log(
                action: "pairing.join",
                resourceType: "device",
                resourceId: response.peerHostId,
                req: req,
            )
            return response
        } catch let error as PairingError {
            throw map(error)
        }
    }

    private func map(_ error: PairingError) -> Error {
        if error.httpStatus == 503 {
            return Abort(.serviceUnavailable, reason: error.localizedDescription)
        }
        if case let .redeemFailed(status, reason) = error, status == 429 {
            return Abort(.tooManyRequests, reason: reason)
        }
        return error.barkVisorError
    }
}

/// Join is console-local during first-run setup; after setup it requires JWT.
struct SetupOrJWTMiddleware: AsyncMiddleware {
    let setup: SetupMiddleware
    let jwt: JWTAuthMiddleware

    func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
        -> Vapor.Response {
        if setup.isSetupComplete {
            return try await jwt.respond(to: request, chainingTo: next)
        }
        return try await next.respond(to: request)
    }
}
