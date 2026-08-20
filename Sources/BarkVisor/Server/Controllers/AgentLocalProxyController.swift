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
        }
    }

    /// Member-side hop: mTLS `:7778` → This Device host API unix-backed WS.
    func registerConsoleTunnels(app: Vapor.Application) {
        registerConsoleTunnel(app: app, kind: .vnc)
        registerConsoleTunnel(app: app, kind: .console)
    }

    private func registerConsoleTunnel(app: Vapor.Application, kind: HomeConsoleKind) {
        app.webSocket(
            "api", "vms", ":id", .constant(kind.rawValue),
            shouldUpgrade: { req in
                // Client cert is required by the agent-plane mTLS listener.
                try HomeConsoleProxy.requireTicket(req)
                let vmID = try req.parameters.require("id")
                let ticket = StreamTicketPolicy.deviceTicket(fromQuery: req.url.query)
                    ?? req.query[String.self, at: StreamTicketPolicy.ticketQueryName]
                    ?? req.query[String.self, at: StreamTicketPolicy.tokenRewriteQueryName]
                guard let ticket,
                      await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: vmID) != nil
                else {
                    throw Abort(.unauthorized, reason: StreamTicketPolicy.expiredTicketReason)
                }
                return [:]
            },
            onUpgrade: { req, inbound in
                Task {
                    await self.tunnelToLocal(req: req, inbound: inbound, kind: kind)
                }
            },
        )
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
        if let vmState {
            let path: String? = switch kind {
            case .vnc: await vmState.vncSocketPath(for: vmID)
            case .console: await vmState.serialSocketPath(for: vmID)
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
    func forward(req: Vapor.Request) async throws -> Response {
        let peer = try requirePeer(req)
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
        let url = try HomeDeviceProxy.localURL(
            port: localPort,
            path: path,
            query: req.url.query,
        )
        let body = try await HomeDevicesController.collectedBody(req)
        var headers: [(String, String)] = []
        if let auth = req.headers.bearerAuthorization {
            headers.append(("Authorization", "Bearer \(auth.token)"))
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
            )
        } catch let error as HomeDeviceProxyError {
            throw Abort(.badGateway, reason: error.localizedDescription)
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .badGateway,
                reason: "Local host API is unreachable: \(error.localizedDescription)",
            )
        }
        return HomeDevicesController.response(from: result)
    }

    private func requirePeer(_ req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }
}
