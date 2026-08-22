import BarkVisorCore
import Foundation
import GRDB
import JWTKit
import Vapor

extension PairingIssueResponse: Content {}
extension PairingRedeemRequest: Content {}
extension PairingRedeemResponse: Content {}
extension PairingJoinRequest: Content {}
extension PairingJoinResponse: Content {}

/// Pairing issue / redeem (PAS-45). Redeem is public, rate-limited, and
/// returns device-trust only. Shared login is copied over mTLS after join
/// (PAS-283). Join uses the same pairing limiter. Join requires a QR
/// payload and is console-local until setup completes, then JWT.
struct PairingController: RouteCollection {
    let offers: PairingOfferStore
    let setupMiddleware: SetupMiddleware
    let jwt: JWTAuthMiddleware
    let pairingRateLimit: RateLimitMiddleware
    let keys: JWTKeyCollection

    func boot(routes: any RoutesBuilder) throws {
        let pairing = routes.grouped("api", "pairing")
        pairing.grouped(pairingRateLimit).post("redeem", use: redeem)
        pairing.grouped(SetupOrJWTMiddleware(setup: setupMiddleware, jwt: jwt), pairingRateLimit)
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
        let advertiseUrl = try await req.db.read { db in
            try RemoteAccessSettings.load(from: db).advertiseUrl
        }
        let hosts = RemoteAccessSettings.advertisedHosts(advertiseUrl: advertiseUrl)
        do {
            let response = try PairingService.issue(
                PairingService.IssueInput(
                    dataDir: Config.dataDir,
                    hostId: Config.hostId,
                    advertisedHost: advertised,
                    advertisedHosts: hosts,
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
            let advertiseUrl = try await req.db.read { db in
                try RemoteAccessSettings.load(from: db).advertiseUrl
            }
            let hosts = RemoteAccessSettings.advertisedHosts(advertiseUrl: advertiseUrl)
            return try PairingService.currentOffer(
                PairingService.IssueInput(
                    dataDir: Config.dataDir,
                    hostId: Config.hostId,
                    advertisedHosts: hosts,
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
        var body: PairingRedeemRequest
        do {
            body = try req.content.decode(PairingRedeemRequest.self)
        } catch {
            throw BarkVisorError.badRequest("Invalid pairing redeem request")
        }
        if body.agentHost == nil {
            let peer = req.remoteAddress?.ipAddress ?? req.peerAddress?.ipAddress
            if let peer, let host = PairingPayload.sanitizeProxyHost(peer) {
                body.agentHost = host
            }
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
                identityClient: AgentMTLSPairingIdentityClient(),
                db: req.db,
                keys: keys,
            )
            // Pairing during first-run setup must not close /api/setup/* —
            // the wizard still needs bridge / repo / catalog steps.
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
        let peer = request.remoteAddress?.ipAddress ?? request.peerAddress?.ipAddress
        guard PairingPayload.isConsoleLocalClient(peer) else {
            throw Abort(.forbidden, reason: "Pairing join during setup is limited to this Device")
        }
        return try await next.respond(to: request)
    }
}
