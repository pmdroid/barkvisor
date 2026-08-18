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

    init(
        localPort: Int = Config.port,
        client: any HomeDeviceProxyClient = LocalHostProxyClient(),
    ) {
        self.localPort = localPort
        self.client = client
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
        let localPort = localPort
        app.webSocket(
            "api", "vms", ":id", .constant(kind.rawValue),
            shouldUpgrade: { req in
                // Client cert is required by the agent-plane mTLS listener.
                try HomeConsoleProxy.requireTicket(req)
                return [:]
            },
            onUpgrade: { req, inbound in
                Task {
                    await Self.tunnelToLocal(
                        req: req,
                        inbound: inbound,
                        kind: kind,
                        localPort: localPort,
                    )
                }
            },
        )
    }

    private static func tunnelToLocal(
        req: Vapor.Request,
        inbound: WebSocket,
        kind: HomeConsoleKind,
        localPort: Int,
    ) async {
        let eventLoop = inbound.eventLoop
        let toRemote = WebSocketPipeBox()
        let toClient = WebSocketPipeBox()
        WebSocketRelay.onEventLoop(inbound) {
            WebSocketRelay.capture(from: inbound, into: toRemote)
        }
        guard let vmID = req.parameters.get("id") else {
            WebSocketRelay.close(inbound)
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
                    query: req.url.query,
                ),
            )
        } catch {
            WebSocketRelay.close(inbound)
            return
        }
        do {
            let remote = try await Task {
                try await HomeWebSocketDialer.open(url: url, on: eventLoop) { ws in
                    WebSocketRelay.capture(from: ws, into: toClient)
                }
            }.value
            if inbound.isClosed {
                WebSocketRelay.close(remote)
                return
            }
            toRemote.attach(remote)
            toClient.attach(inbound)
            WebSocketRelay.bindCloses(local: inbound, remote: remote)
        } catch {
            Log.server.error(
                "Agent console tunnel failed: \(error.localizedDescription)",
            )
            WebSocketRelay.close(inbound)
        }
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
