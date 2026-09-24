import BarkVisorCore
import Vapor

/// Agent-plane catch-all: forward mTLS `/api/*` to this Device's host API.
///
/// `GET /api/agent/whoami` stays on the agent listener. Nested
/// `/api/home/*` is rejected so a member cannot recurse the proxy.
/// Setup and pairing join stay off this path: the loopback hop would
/// look console-local to the host API. Incoming paths are decoded
/// and rejected for `.` / `..` before those guards run.
struct AgentLocalProxyController: RouteCollection {
    var localPort: Int
    var client: any HomeDeviceProxyClient
    var dialer: any HomeWebSocketDialing
    var vmState: (any VMStateQuerying)?
    var consoleBuffers: ConsoleBufferManager?

    init(
        localPort: Int = Config.port,
        client: any HomeDeviceProxyClient = LocalHostProxyClient(),
        dialer: (any HomeWebSocketDialing)? = nil,
        vmState: (any VMStateQuerying)? = nil,
        consoleBuffers: ConsoleBufferManager? = nil,
    ) {
        self.localPort = localPort
        self.client = client
        self.dialer = dialer ?? PlainWebSocketDialer()
        self.vmState = vmState
        self.consoleBuffers = consoleBuffers
    }

    func boot(routes: any RoutesBuilder) throws {
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE] {
            routes.on(method, "api", "**", use: forward)
            routes.on(method, "go", ":id", use: forwardGo)
            routes.on(method, "go", ":id", "**", use: forwardGo)
        }
    }

    /// Member-side hop: mTLS `:7778` → This Device host API unix-backed WS.
    func registerConsoleTunnels(app: Vapor.Application) {
        registerConsoleTunnel(app: app, kind: .vnc)
        registerConsoleTunnel(app: app, kind: .console)
        registerConsoleTunnel(app: app, kind: .terminal)
        registerSystemTerminalTunnel(app: app)
    }

    private func registerSystemTerminalTunnel(app: Vapor.Application) {
        app.webSocket(
            "api", "system", "terminal",
            shouldUpgrade: { req in
                let ticket = StreamTicketPolicy.deviceTicket(fromQuery: req.url.query)
                    ?? req.query[String.self, at: StreamTicketPolicy.ticketQueryName]
                    ?? req.query[String.self, at: StreamTicketPolicy.tokenRewriteQueryName]
                do {
                    try StreamTicketPolicy.requirePassThroughDeviceTicket(ticket)
                } catch let error as BarkVisorError {
                    throw Abort(.unauthorized, reason: error.errorDescription ?? "Unauthorized")
                }
                return [:]
            },
            onUpgrade: { req, inbound in
                Task {
                    await self.tunnelSystemTerminal(req: req, inbound: inbound)
                }
            },
        )
    }

    func tunnelSystemTerminal(inbound: any WebSocketHopPeer, query: String?) async {
        let url: URL
        do {
            url = try HomeDeviceProxy.systemTerminalURL(
                HomeSystemTerminalTarget(
                    isSelf: true,
                    localPort: localPort,
                    agentHost: nil,
                    agentPort: localPort,
                    query: query,
                ),
            )
        } catch {
            inbound.close()
            return
        }
        await WebSocketHop.run(inbound: inbound, url: url, dialer: dialer)
    }

    private func tunnelSystemTerminal(req: Vapor.Request, inbound: WebSocket) async {
        await tunnelSystemTerminal(inbound: VaporWebSocketPeer(inbound), query: req.url.query)
    }

    private func registerConsoleTunnel(app: Vapor.Application, kind: HomeConsoleKind) {
        app.webSocket(
            "api", "vms", ":id", .constant(kind.rawValue),
            shouldUpgrade: { req in
                _ = try self.requireActivePeer(req)
                try await Self.requireTunnelTicket(kind: kind, req: req)
                return [:]
            },
            onUpgrade: { req, inbound in
                Task {
                    let host = req.mtlsPeer?.hostId ?? ""
                    let stream = await PrivilegedStreamGate.shared.register(
                        memberHostId: host,
                        close: { inbound.close(promise: nil) },
                    )
                    await self.tunnelToLocal(req: req, inbound: inbound, kind: kind)
                    await PrivilegedStreamGate.shared.end(stream)
                }
            },
        )
    }

    /// Tunnel ticket gate on the agent plane (issue #614).
    ///
    /// VNC and serial terminate *here* (QEMU / `ConsoleBufferManager`), so the
    /// one-use Device ticket is spent on this agent. The app terminal does not:
    /// its hop dials the host API's `TerminalController`, which must spend the
    /// ticket there — spending it twice was the instant-close/401 reconnect
    /// loop. For `.terminal` we therefore only require presence + UUID shape
    /// (pass-through, same contract as Home's `requireTicket`).
    static func requireTunnelTicket(kind: HomeConsoleKind, req: Vapor.Request) async throws {
        let vmID = try req.parameters.require("id")
        let ticket = StreamTicketPolicy.deviceTicket(fromQuery: req.url.query)
            ?? req.query[String.self, at: StreamTicketPolicy.ticketQueryName]
            ?? req.query[String.self, at: StreamTicketPolicy.tokenRewriteQueryName]
        try await requireTunnelTicket(kind: kind, vmID: vmID, ticket: ticket)
    }

    /// Split out from the Vapor request so the table is testable without a
    /// routing context. Shape-checks for every kind; spends only when the
    /// tunnel terminates on this agent (see `requireTunnelTicket(kind:req:)`).
    static func requireTunnelTicket(
        kind: HomeConsoleKind,
        vmID: String,
        ticket: String?,
        ticketStore: WebSocketTicketStore = .shared,
    ) async throws {
        do {
            try StreamTicketPolicy.requirePassThroughDeviceTicket(ticket)
        } catch let error as BarkVisorError {
            throw Abort(.unauthorized, reason: error.errorDescription ?? "Unauthorized")
        }
        guard let ticket, kind != .terminal else { return }
        guard await ticketStore.validateTicket(ticket, forVMID: vmID) != nil
        else {
            throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredTicketReason)
        }
    }

    private func tunnelToLocal(
        req: Vapor.Request,
        inbound: WebSocket,
        kind: HomeConsoleKind,
    ) async {
        guard let vmID = req.parameters.get("id") else {
            WebSocketRelay.close(inbound)
            return
        }
        await tunnel(
            inbound: VaporWebSocketPeer(inbound),
            vmID: vmID,
            kind: kind,
            query: req.url.query,
        )
    }

    /// VNC hops to the QEMU unix socket (PAS-224). Serial hops to
    /// `ConsoleBufferManager` so scrollback and extra subscribers survive
    /// (PAS-233). Looping VNC through `:7777` dropped the RFB banner.
    func tunnel(
        inbound: any WebSocketHopPeer,
        vmID: String,
        kind: HomeConsoleKind,
        query: String?,
    ) async {
        if kind == .console, let consoleBuffers {
            guard await consoleBuffers.isSerialLive(vmID: vmID) else {
                Log.server.error("Agent console hop: no live serial for \(vmID)")
                inbound.close()
                return
            }
            await WebSocketHop.run(
                inbound: inbound,
                farEnd: ConsoleBufferHopFarEnd(buffers: consoleBuffers, vmID: vmID),
                logTarget: "serial:\(vmID)",
            )
            return
        }
        // The app terminal has no QEMU/serial socket: `docker exec` lives on the
        // host API, so `.terminal` always takes the URL hop to `TerminalController`
        // below — even when `vmState` is configured (issue #614; mapping it to a
        // nil socket closed member tunnels instantly).
        if kind != .terminal, let vmState {
            let path: String? = switch kind {
            case .vnc: await vmState.vncSocketPath(for: vmID)
            case .console: await vmState.serialSocketPath(for: vmID)
            case .terminal: nil
            }
            guard let path else {
                Log.server.error("Agent console hop: no \(kind.rawValue) socket for \(vmID)")
                inbound.close()
                return
            }
            await WebSocketHop.run(inbound: inbound, unixSocketPath: path)
            return
        }
        let url: URL
        do {
            url = try HomeDeviceProxy.consoleTargetURL(
                HomeConsoleTarget(
                    isSelf: true,
                    localPort: localPort,
                    agentHost: nil,
                    agentPort: localPort,
                    vmID: vmID,
                    kind: kind,
                    query: query,
                ),
            )
        } catch {
            inbound.close()
            return
        }
        await WebSocketHop.run(inbound: inbound, url: url, dialer: dialer)
    }

    @Sendable
    func forwardGo(req: Vapor.Request) async throws -> Response {
        _ = try requireActivePeer(req)
        let id = try req.parameters.require("id")
        let remainder = req.parameters.getCatchall()
        let path = try HomeDeviceProxy.goPath(id: id, remainder: remainder)
        if req.headers[.upgrade].joined(separator: " ").lowercased().contains("websocket") {
            return req.webSocket { req, inbound in
                Task {
                    do {
                        let http = try HomeDeviceProxy.localURL(
                            port: self.localPort, path: path, query: req.url.query,
                        )
                        let url = try HomeDeviceProxy.webSocketURL(from: http)
                        await WebSocketHop.run(inbound: inbound, url: url, dialer: self.dialer)
                    } catch {
                        WebSocketRelay.close(inbound)
                    }
                }
            }
        }
        return try await hopLocal(req: req, path: path)
    }

    @Sendable
    func forward(req: Vapor.Request) async throws -> Response {
        let peer = try requireActivePeer(req)
        try HomeConsoleProxy.rejectStrippedUpgrade(req)
        let path = try HomeDeviceProxy.normalizedAPIPath(req.url.path)
        if path == "/api/agent/whoami" {
            let response = Response(status: .ok)
            try response.content.encode(peer)
            return response
        }
        try HomeDeviceProxy.rejectNestedHome(path)
        try HomeDeviceProxy.rejectConsoleLocalOnly(path)
        guard path.hasPrefix("/api/") else {
            throw BarkVisorError.badRequest("Invalid member API path")
        }
        return try await hopLocal(req: req, path: path)
    }

    private func hopLocal(req: Vapor.Request, path: String) async throws -> Response {
        let url = try HomeDeviceProxy.localURL(
            port: localPort,
            path: path,
            query: req.url.query,
        )
        let body = try await HomeDevicesController.collectedBody(req)
        var headers: [(String, String)] = []
        if let authorization = try await translatedAuthorization(req) {
            headers.append(("Authorization", "Bearer \(authorization)"))
        }
        if let type = req.headers.contentType {
            headers.append(("Content-Type", type.serialize()))
        }
        if let accept = req.headers.first(name: .accept) {
            headers.append(("Accept", accept))
        }
        headers.append((APIContract.versionHeaderName, String(APIContract.version)))

        let result: HomeDeviceProxyResponse
        do {
            result = try await client.send(
                HomeDeviceProxyRequest(
                    method: req.method.rawValue,
                    url: url,
                    headers: headers,
                    body: body,
                ),
                timeout: Self.generationTimeout(for: path),
            )
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .badGateway,
                reason: HomeDeviceProxyError.classify(error).localHopDescription,
            )
        }
        return HomeDevicesController.response(from: result)
    }

    /// Generation paths wait on cold model loads and slow first tokens; the
    /// 10s control-plane loopback default aborts them mid-flight ("Local host
    /// API timed out"). Grant the completions endpoint the stream timeout.
    static func generationTimeout(for path: String) -> TimeInterval? {
        path == OllamaChatProxy.deviceCompletionsPath
            ? TimeInterval(OllamaChatProxy.streamTimeoutSeconds)
            : nil
    }

    private func requirePeer(_ req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }

    private func requireActivePeer(_ req: Vapor.Request) throws -> AgentPeerIdentity {
        let names = req.headers.map(\.name)
        if ForwardedIdentity.rejects(headerNames: names) {
            throw Abort(.unauthorized, reason: "Forwarded identity is not accepted")
        }
        let peer = try requirePeer(req)
        let decision = HomeMembershipAuthority(dataDir: Config.dataDir).authorizeCertificate(
            hostId: peer.hostId,
            fingerprint: peer.fingerprint,
        )
        guard case .allow = decision else {
            throw Abort(.unauthorized, reason: "Home membership denied this Device")
        }
        return peer
    }

    private func translatedAuthorization(_ req: Vapor.Request) async throws -> String? {
        guard let token = req.headers.bearerAuthorization?.token else { return nil }
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        if token.hasPrefix(HomeScopedCredential.prefix) {
            guard let certificate = req.mtlsPeerCertificatePEM else {
                throw Abort(.unauthorized, reason: "Client certificate required")
            }
            let scoped = try HomeScopedCredential.verify(
                token: token,
                issuerCertificatePEM: certificate,
            )
            guard scoped.issuerHostId.caseInsensitiveCompare(peer.hostId) == .orderedSame else {
                throw Abort(.unauthorized, reason: "Hop credential is not bound to the presented Device")
            }
            let authority = HomeMembershipAuthority(dataDir: Config.dataDir)
            let decision = authority.authorizeLoginToken(
                issuerHostId: scoped.issuerHostId,
                subjectHostId: nil,
                issuedAt: scoped.issuedAt,
                expiresAt: scoped.expiresAt,
                membershipRevision: scoped.membershipRevision,
                localHostId: Config.hostId,
            )
            guard case .allow = decision else {
                throw Abort(.unauthorized, reason: "Home membership denied this login token")
            }
            let managementKey = try authority.managementKeyPEM()
            return try HomeManagementCredential.sign(
                issuerHostId: Config.hostId,
                subject: scoped.subject,
                username: scoped.username,
                role: scoped.role,
                onBehalfOfHostId: peer.hostId,
                membershipRevision: scoped.membershipRevision,
                managementKeyPEM: managementKey,
            )
        }
        if HomeMembershipAuthority.ledgerExists(dataDir: Config.dataDir) {
            throw Abort(
                .unauthorized,
                reason: "Member hop credential is not bound to the presented Device",
            )
        }
        return token
    }
}
