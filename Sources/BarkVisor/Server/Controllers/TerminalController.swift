import BarkVisorCore
import Foundation
import GRDB
import NIOCore
import Vapor

/// App-workload terminal (issue #609): `WS /api/vms/:id/terminal?service=…`
/// spawns `docker exec -it <container> sh` on a PTY and bridges it to the
/// socket via `DockerExecHopFarEnd`. Plus `GET /api/vms/:id/containers` for
/// the service picker.
///
/// Gating (mirrors `ConsoleController`'s ticket shape, then RBAC): one-use
/// `ticket=` scoped to the Workload is spent on this Device; the user must be
/// admin (exec is root-equivalent on the Device); classic VMs 404 (they have
/// the serial console); an unknown/foreign `service=` is 400; a stopped app
/// gets a text status frame + clean close. Session opens are audit-logged.
struct TerminalController: RouteCollection {
    static let pathTail = "terminal"
    static let auditAction = "workload.terminal.open"

    struct Decision: Equatable {
        enum Status: String {
            case accept
            case rejectUnauthorized // missing/spent/foreign ticket → 401
            case rejectForbidden // inference (non-admin) → 403
            case rejectNotFound // unknown Workload or classic VM → 404
            case rejectBadRequest // missing/invalid/foreign service → 400
            case closeNotRunning // app exists but stopped → text frame + close
        }

        var status: Status

        var webSocketAbort: HTTPStatus? {
            switch status {
            case .accept, .closeNotRunning: return nil
            case .rejectUnauthorized: return .unauthorized
            case .rejectForbidden: return .forbidden
            case .rejectNotFound: return .notFound
            case .rejectBadRequest: return .badRequest
            }
        }
    }

    /// Pure gate so the table is testable without Vapor or docker. Order is
    /// contractual: ticket first (no existence oracle for unauthenticated
    /// callers), then role, then workload kind, then service, running last.
    static func decide(
        ticketValid: Bool,
        isAdmin: Bool,
        workloadExists: Bool,
        isApplication: Bool,
        serviceValid: Bool,
        isRunning: Bool,
    ) -> Decision {
        guard ticketValid else { return Decision(status: .rejectUnauthorized) }
        guard isAdmin else { return Decision(status: .rejectForbidden) }
        guard workloadExists, isApplication else { return Decision(status: .rejectNotFound) }
        guard serviceValid else { return Decision(status: .rejectBadRequest) }
        guard isRunning else { return Decision(status: .closeNotRunning) }
        return Decision(status: .accept)
    }

    /// Whether the ticket's principal may open an exec terminal. A real user
    /// needs a persisted admin `User` row; the auth-disabled bypass principal
    /// (`AuthBypass.syntheticUserId`) is minted without a row but *is* the
    /// single local owner, so it counts as admin only where bypass is actually
    /// allowed (`AuthBypass.allows`) — never under `.secure`. Without this the
    /// `User.fetchOne` lookup of the synthetic id returns nil and a correctly
    /// configured auth-disabled Device wrongly rejects every terminal as 403.
    static func resolveIsAdmin(
        userID: String,
        persistedIsAdmin: Bool,
        bypassAllowed: Bool,
    ) -> Bool {
        if userID == AuthBypass.syntheticUserId {
            return bypassAllowed
        }
        return persistedIsAdmin
    }

    /// `service=` from the socket query (same item reader the ticket uses).
    static func requestedService(inQuery query: String?) -> String? {
        let items = StreamTicketPolicy.queryItems(from: query)
        return StreamTicketPolicy.firstValue(items, name: StreamTicketPolicy.serviceQueryName)
    }

    /// Initial grid size from the connect query (`?cols=&rows=`, issue #614).
    /// The server's pre-spawn checks (`docker compose ps`) block past the
    /// client's first resize frame, so the SPA rides its measured size on the
    /// URL and the PTY is born with the right winsize instead of 80×24.
    /// Absent/garbage values fall back to the request defaults; values are
    /// clamped so a hostile query can not size the PTY absurdly.
    static func requestedWindowSize(
        inQuery query: String?,
    ) -> (cols: Int, rows: Int)? {
        let items = StreamTicketPolicy.queryItems(from: query)
        guard let cols = clampedDimension(
            StreamTicketPolicy.firstValue(items, name: StreamTicketPolicy.colsQueryName),
        ),
            let rows = clampedDimension(
                StreamTicketPolicy.firstValue(items, name: StreamTicketPolicy.rowsQueryName),
            )
        else { return nil }
        return (cols, rows)
    }

    private static func clampedDimension(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard value > 0 else { return nil }
        return min(value, Self.maxWindowDimension)
    }

    static let maxWindowDimension = 9_999

    // MARK: - REST (service picker)

    func boot(routes: any RoutesBuilder) throws {
        // JWT-protected registration happens in routes.swift; the WS upgrade
        // below self-authenticates with a one-use ticket like console/vnc.
        routes.on(.GET, "api", "vms", ":id", "containers") { req -> [WorkloadContainerResponse] in
            try await Self.containersPayload(req: req)
        }
    }

    static func containersPayload(req: Vapor.Request) async throws -> [WorkloadContainerResponse] {
        let vmID = try req.parameters.require("id")
        let snapshot: (exists: Bool, isApplication: Bool, project: String?) =
            try await req.db.read { db in
                guard let vm = try VM.fetchOne(db, key: vmID) else { return (false, false, nil) }
                return (
                    true,
                    vm.isApplication,
                    vm.composeProject ?? ComposeRuntime.composeProjectName(id: vmID),
                )
            }
        guard snapshot.exists, snapshot.isApplication else {
            throw Abort(.notFound)
        }
        return try ContainerResolver.listContainers(
            id: vmID,
            project: snapshot.project ?? ComposeRuntime.composeProjectName(id: vmID),
        ).map { WorkloadContainerResponse(service: $0.service, name: $0.name, state: $0.state) }
    }

    // MARK: - WebSocket

    func register(app: Vapor.Application) {
        #if !os(Windows)
            app.webSocket(
                "api", "vms", ":id", .constant(Self.pathTail),
                shouldUpgrade: { req in
                    let vmID = try req.parameters.require("id")
                    guard let ticket = StreamTicketPolicy.deviceTicket(fromQuery: req.url.query)
                        ?? req.query[String.self, at: StreamTicketPolicy.ticketQueryName]
                    else {
                        throw Abort(.unauthorized, reason: StreamTicketPolicy.missingTicketReason)
                    }
                    guard let identity = await WebSocketTicketStore.shared.validateTicket(
                        ticket, forVMID: vmID,
                    ) else {
                        throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredTicketReason)
                    }
                    let persistedIsAdmin: Bool = if identity.userID == AuthBypass.syntheticUserId {
                        // Auth-disabled / loopback owner is minted without a User row.
                        false
                    } else {
                        try await req.db.read { db in
                            try User.fetchOne(db, key: identity.userID)?.userRole == .admin
                        }
                    }
                    let isAdmin = Self.resolveIsAdmin(
                        userID: identity.userID,
                        persistedIsAdmin: persistedIsAdmin,
                        bypassAllowed: AuthBypass.allows(req),
                    )
                    let service = Self.requestedService(inQuery: req.url.query)
                    let decision = try await Self.precheck(
                        req: req,
                        vmID: vmID,
                        isAdmin: isAdmin,
                        service: service,
                    )
                    if let abort = decision.webSocketAbort {
                        throw Abort(abort, reason: Self.rejectReason(decision.status))
                    }
                    req.storage[TerminalSessionKey.self] = TerminalSession(
                        userID: identity.userID,
                        username: identity.username,
                        service: service ?? "",
                    )
                    return [:]
                },
                onUpgrade: { req, ws in
                    let vmID = (try? req.parameters.require("id")) ?? ""
                    let query = req.url.query
                    Task {
                        await self.serve(req: req, ws: ws, vmID: vmID, query: query)
                    }
                },
            )
        #endif
    }

    #if !os(Windows)
        struct TerminalSession {
            var userID: String
            var username: String
            var service: String
        }

        /// Cheap DB checks + project-scoped service membership. Docker `ps` runs
        /// here so a bad `service=` rejects with 400 before the socket opens.
        private static func precheck(
            req: Vapor.Request,
            vmID: String,
            isAdmin: Bool,
            service: String?,
        ) async throws -> Decision {
            let vm: VM? = try await req.db.read { db in try VM.fetchOne(db, key: vmID) }
            var serviceValid = false
            if let service, ContainerResolver.isValidServiceName(service) {
                let project = vm?.composeProject ?? ComposeRuntime.composeProjectName(id: vmID)
                if let containers = try? ContainerResolver.listContainers(id: vmID, project: project),
                   (try? ContainerResolver.resolve(containers: containers, service: service)) != nil {
                    serviceValid = true
                }
            }
            // The ticket already passed (spent above); encode it as valid here.
            return Self.decide(
                ticketValid: true,
                isAdmin: isAdmin,
                workloadExists: vm != nil,
                isApplication: vm?.isApplication == true,
                serviceValid: serviceValid,
                isRunning: vm?.state == "running",
            )
        }

        private static func rejectReason(_ status: Decision.Status) -> String {
            switch status {
            case .rejectForbidden: return "Admin only"
            case .rejectNotFound: return "Workload not found"
            case .rejectBadRequest: return "Unknown or invalid service"
            case .accept, .closeNotRunning, .rejectUnauthorized: return ""
            }
        }

        private func serve(
            req: Vapor.Request,
            ws inbound: WebSocket,
            vmID: String,
            query: String?,
        ) async {
            let eventLoop = req.eventLoop
            // Keepalive (#614): idle exec sessions sat past NAT/LB socket timeouts and
            // dropped mid-think. Server pings every 20 s; an unanswered pong closes
            // the socket so the client's reconnect machine takes over.
            inbound.pingInterval = .seconds(20)
            let session = req.storage[TerminalSessionKey.self]
            let service = session?.service ?? ""

            guard !service.isEmpty, ContainerResolver.isValidServiceName(service) else {
                eventLoop.execute {
                    inbound.send("Missing service.\r\n", promise: nil)
                    inbound.close(code: .normalClosure, promise: nil)
                }
                return
            }

            let plan: (name: String, container: String, state: String)?
            do {
                plan = try await Self.resolveExecTarget(req: req, vmID: vmID, service: service)
            } catch {
                eventLoop.execute {
                    inbound.send("Terminal unavailable: \(error.localizedDescription)\r\n", promise: nil)
                    inbound.close(code: .normalClosure, promise: nil)
                }
                return
            }
            guard let plan else {
                eventLoop.execute {
                    inbound.send("Workload not found.\r\n", promise: nil)
                    inbound.close(code: .normalClosure, promise: nil)
                }
                return
            }
            guard plan.state == "running" else {
                eventLoop.execute {
                    inbound.send("App is not running.\r\n", promise: nil)
                    inbound.close(code: .normalClosure, promise: nil)
                }
                return
            }

            guard let sessionHandle = try? DockerExecSession() else {
                eventLoop.execute {
                    inbound.send("docker not available on this Device.\r\n", promise: nil)
                    inbound.close(code: .normalClosure, promise: nil)
                }
                return
            }

            AuditService.log(
                action: Self.auditAction,
                resourceType: "vm",
                resourceId: vmID,
                resourceName: plan.name,
                detail: "service=\(service) container=\(plan.container)",
                userId: session?.userID,
                username: session?.username,
                authMethod: "ticket",
                db: req.db,
            )

            // Spawn at the client-measured grid (`?cols=&rows=`) so the shell is
            // born with the right winsize; the earlier live resize frames that
            // raced past the blocking `docker compose ps` precheck no longer
            // matter for the initial size (#614).
            let size = Self.requestedWindowSize(inQuery: query)
            let request = DockerExecRequest(
                container: plan.container,
                shell: DockerExecSession.defaultShell,
                cols: size?.cols ?? DockerExecRequest.defaultCols,
                rows: size?.rows ?? DockerExecRequest.defaultRows,
            )
            await WebSocketHop.run(
                inbound: VaporWebSocketPeer(inbound),
                farEnd: DockerExecHopFarEnd(session: sessionHandle, request: request),
                logTarget: "exec:\(plan.container)",
            )
        }

        /// Re-validates exec membership server-side at spawn time (TOCTOU guard
        /// between the precheck `ps` and the exec): the container must still
        /// belong to this Workload's compose project.
        private static func resolveExecTarget(
            req: Vapor.Request,
            vmID: String,
            service: String,
        ) async throws -> (name: String, container: String, state: String)? {
            let vm: VM? = try await req.db.read { db in try VM.fetchOne(db, key: vmID) }
            guard let vm, vm.isApplication else { return nil }
            let project = vm.composeProject ?? ComposeRuntime.composeProjectName(id: vmID)
            let containers = try ContainerResolver.listContainers(id: vmID, project: project)
            guard let match = try? ContainerResolver.resolve(containers: containers, service: service)
            else { return nil }
            return (vm.name, match.name, vm.state)
        }
    #endif
}

private struct TerminalSessionKey: StorageKey {
    typealias Value = TerminalController.TerminalSession
}

struct WorkloadContainerResponse: Content {
    let service: String
    let name: String
    let state: String
}
