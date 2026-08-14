import BarkVisorCore
import Vapor

/// Agent-plane catch-all: forward mTLS `/api/*` to this Device's host API.
///
/// `GET /api/agent/whoami` stays on the agent listener. Nested
/// `/api/home/*` is rejected so a member cannot recurse the proxy.
/// Setup and pairing join stay off this path: the loopback hop would
/// look console-local to the host API.
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

    @Sendable
    func forward(req: Vapor.Request) async throws -> Response {
        let peer = try requirePeer(req)
        let path = req.url.path
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
