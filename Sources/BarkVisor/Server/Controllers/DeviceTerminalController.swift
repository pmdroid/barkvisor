import BarkVisorCore
import Foundation
import GRDB
import NIOCore
import Vapor

struct DeviceTerminalController: RouteCollection {
    static let auditAction = "device.terminal.open"
    static let windowsReason = "Device terminal is not available on Windows"

    struct Decision: Equatable {
        enum Status: String {
            case accept
            case rejectUnauthorized
            case rejectForbidden
            case rejectBadRequest
            case rejectNotImplemented
        }

        var status: Status

        var webSocketAbort: HTTPStatus? {
            switch status {
            case .accept: return nil
            case .rejectUnauthorized: return .unauthorized
            case .rejectForbidden: return .forbidden
            case .rejectBadRequest: return .badRequest
            case .rejectNotImplemented: return .notImplemented
            }
        }
    }

    static func decide(
        ticketValid: Bool,
        isAdmin: Bool,
        platformSupported: Bool,
        accountAllowed: Bool,
    ) -> Decision {
        guard ticketValid else { return Decision(status: .rejectUnauthorized) }
        guard isAdmin else { return Decision(status: .rejectForbidden) }
        guard platformSupported else { return Decision(status: .rejectNotImplemented) }
        guard accountAllowed else { return Decision(status: .rejectBadRequest) }
        return Decision(status: .accept)
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "system", "users", use: listUsers)
    }

    func register(app: Vapor.Application) {
        #if !os(Windows)
            app.webSocket(
                "api", "system", "terminal",
                shouldUpgrade: { req in
                    guard let ticket = StreamTicketPolicy.deviceTicket(fromQuery: req.url.query)
                        ?? req.query[String.self, at: StreamTicketPolicy.ticketQueryName]
                    else {
                        throw Abort(.unauthorized, reason: StreamTicketPolicy.missingTicketReason)
                    }
                    guard let identity = await WebSocketTicketStore.shared.validateTicket(
                        ticket, hostID: Config.hostId,
                    ) else {
                        throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredTicketReason)
                    }
                    let persistedIsAdmin: Bool = if identity.userID == AuthBypass.syntheticUserId {
                        false
                    } else {
                        try await req.db.read { db in
                            try User.fetchOne(db, key: identity.userID)?.userRole == .admin
                        }
                    }
                    let isAdmin = TerminalController.resolveIsAdmin(
                        userID: identity.userID,
                        persistedIsAdmin: persistedIsAdmin,
                        bypassAllowed: AuthBypass.allows(req),
                    )
                    let accountAllowed = DeviceLoginAccount.spawnRecord(name: identity.osUser) != nil
                    let decision = Self.decide(
                        ticketValid: true,
                        isAdmin: isAdmin,
                        platformSupported: true,
                        accountAllowed: accountAllowed,
                    )
                    if let abort = decision.webSocketAbort {
                        throw Abort(abort, reason: Self.rejectReason(decision.status))
                    }
                    req.storage[DeviceTerminalSessionKey.self] = DeviceTerminalSession(
                        userID: identity.userID,
                        username: identity.username,
                        osUser: identity.osUser,
                    )
                    return [:]
                },
                onUpgrade: { req, ws in
                    let query = req.url.query
                    Task {
                        await self.serve(req: req, ws: ws, query: query)
                    }
                },
            )
        #endif
    }

    @Sendable
    func listUsers(req: Vapor.Request) async throws -> [DeviceLoginUserResponse] {
        let user = try req.requireUser
        guard user.userRole == .admin else {
            throw BarkVisorError.forbidden("Admin only")
        }
        #if os(Windows)
            throw Abort(.notImplemented, reason: Self.windowsReason)
        #else
            return DeviceLoginAccount.list().map {
                DeviceLoginUserResponse(name: $0.name, uid: $0.uid, home: $0.home, shell: $0.shell)
            }
        #endif
    }

    private static func rejectReason(_ status: Decision.Status) -> String {
        switch status {
        case .rejectForbidden: return "Admin only"
        case .rejectBadRequest: return "Unknown or disallowed account"
        case .rejectNotImplemented: return windowsReason
        case .accept, .rejectUnauthorized: return ""
        }
    }

    struct DeviceTerminalSession {
        var userID: String
        var username: String
        var osUser: String
    }

    #if !os(Windows)
        private func serve(req: Vapor.Request, ws inbound: WebSocket, query: String?) async {
            let eventLoop = req.eventLoop
            inbound.pingInterval = .seconds(20)
            let session = req.storage[DeviceTerminalSessionKey.self]
            guard let osUser = session?.osUser, let record = DeviceLoginAccount.spawnRecord(name: osUser)
            else {
                eventLoop.execute {
                    inbound.send("Unknown or disallowed account.\r\n", promise: nil)
                    inbound.close(code: .normalClosure, promise: nil)
                }
                return
            }

            AuditService.log(
                action: Self.auditAction,
                resourceType: "device",
                resourceId: Config.hostId,
                resourceName: osUser,
                detail: "uid=\(record.uid)",
                userId: session?.userID,
                username: session?.username,
                authMethod: "ticket",
                db: req.db,
            )

            let size = TerminalController.requestedWindowSize(inQuery: query)
            let request = DeviceShellRequest(
                account: osUser,
                cols: size?.cols ?? DeviceShellRequest.defaultCols,
                rows: size?.rows ?? DeviceShellRequest.defaultRows,
            )
            await WebSocketHop.run(
                inbound: VaporWebSocketPeer(inbound),
                farEnd: DeviceShellHopFarEnd(session: DeviceShellSession(), request: request),
                logTarget: "device-shell:\(osUser)",
            )
        }
    #endif
}

private struct DeviceTerminalSessionKey: StorageKey {
    typealias Value = DeviceTerminalController.DeviceTerminalSession
}

struct DeviceLoginUserResponse: Content {
    let name: String
    let uid: UInt32
    let home: String
    let shell: String
}
