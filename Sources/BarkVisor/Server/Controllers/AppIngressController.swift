import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct AppIngressController: RouteCollection {
    var dataDir: URL
    var hostId: String
    var localPort: Int
    var devices: DeviceRegistry?
    var mtlsClient: (any HomeDeviceProxyClient)?
    var localClient: any HomeDeviceProxyClient
    var dialer: any HomeWebSocketDialing

    init(
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
        localPort: Int = Config.port,
        devices: DeviceRegistry? = nil,
        mtlsClient: (any HomeDeviceProxyClient)? = nil,
        localClient: any HomeDeviceProxyClient = LocalHostProxyClient(timeout: 60),
        dialer: (any HomeWebSocketDialing)? = nil,
    ) {
        self.dataDir = dataDir
        self.hostId = hostId
        self.localPort = localPort
        self.devices = devices
        self.mtlsClient = mtlsClient
        self.localClient = localClient
        self.dialer = dialer ?? PlainWebSocketDialer()
    }

    func boot(routes: any RoutesBuilder) throws {
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE] {
            routes.on(method, "go", ":id", use: localGo)
            routes.on(method, "go", ":id", "**", use: localGo)
            routes.on(method, "home", "devices", ":hostId", "go", ":id", use: homeGo)
            routes.on(method, "home", "devices", ":hostId", "go", ":id", "**", use: homeGo)
        }
    }

    @Sendable
    func localGo(req: Vapor.Request) async throws -> Response {
        _ = try req.requireUser
        let id = try req.parameters.require("id")
        let remainder = req.parameters.getCatchall()
        let path = try HomeDeviceProxy.goPath(id: id, remainder: remainder)
        if wantsWebSocket(req) {
            return upgradeLocal(req: req, id: id, path: path)
        }
        return try await forwardLocal(req: req, id: id, path: path)
    }

    @Sendable
    func homeGo(req: Vapor.Request) async throws -> Response {
        _ = try req.requireUser
        let host = try req.parameters.require("hostId")
        let id = try req.parameters.require("id")
        let remainder = req.parameters.getCatchall()
        let path = try HomeDeviceProxy.goPath(id: id, remainder: remainder)
        if host == hostId {
            if wantsWebSocket(req) {
                return upgradeLocal(req: req, id: id, path: path)
            }
            return try await forwardLocal(req: req, id: id, path: path)
        }
        if wantsWebSocket(req) {
            return upgradeMember(req: req, hostId: host, path: path)
        }
        return try await forwardMember(req: req, hostId: host, path: path)
    }

    private func wantsWebSocket(_ req: Vapor.Request) -> Bool {
        req.headers[.upgrade].joined(separator: " ").lowercased().contains("websocket")
    }

    private func upgradeLocal(req: Vapor.Request, id: String, path: String) -> Response {
        req.webSocket { req, inbound in
            Task {
                do {
                    let url = try await self.localTarget(req: req, id: id, path: path, websocket: true)
                    await WebSocketHop.run(inbound: inbound, url: url, dialer: self.dialer)
                } catch {
                    WebSocketRelay.close(inbound)
                }
            }
        }
    }

    private func upgradeMember(req: Vapor.Request, hostId: String, path: String) -> Response {
        req.webSocket { req, inbound in
            Task {
                do {
                    let url = try self.memberTarget(
                        hostId: hostId, path: path, query: req.url.query, websocket: true,
                    )
                    await WebSocketHop.run(
                        inbound: inbound,
                        url: url,
                        dialer: HomeWebSocketDialer(dataDir: self.dataDir, hostId: self.hostId),
                    )
                } catch {
                    WebSocketRelay.close(inbound)
                }
            }
        }
    }

    private func forwardLocal(req: Vapor.Request, id: String, path: String) async throws -> Response {
        let url = try await localTarget(req: req, id: id, path: path, websocket: false)
        return try await send(req: req, url: url, client: localClient, stripAuth: true)
    }

    private func forwardMember(req: Vapor.Request, hostId: String, path: String) async throws -> Response {
        let url = try memberTarget(hostId: hostId, path: path, query: req.url.query, websocket: false)
        let client: any HomeDeviceProxyClient
        if let mtlsClient {
            client = mtlsClient
        } else {
            do {
                client = try HomeDevicesMTLS.client(dataDir: dataDir, hostId: self.hostId)
            } catch {
                throw Abort(
                    .serviceUnavailable,
                    reason: "Cannot reach members yet; local runtime continues",
                )
            }
        }
        return try await send(req: req, url: url, client: client, stripAuth: false)
    }

    private func localTarget(
        req: Vapor.Request,
        id: String,
        path: String,
        websocket: Bool,
    ) async throws -> URL {
        let vm = try await req.db.read { db in try VM.fetchOne(db, key: id) }
        guard let vm, vm.isApplication else {
            throw BarkVisorError.notFound("Workload not found")
        }
        let spec = WorkloadSpecProjector.fromVM(vm)
        guard AppIngress.usesPrefix(catalogProxy: spec.spec.ingress?.mode, ingress: spec.spec.ingress)
        else {
            throw BarkVisorError.notFound("Workload is not published through BarkVisor")
        }
        let ports = vm.decodedPortForwards.map {
            PublishedPort(hostPort: $0.hostPort, containerPort: $0.guestPort, proto: $0.protocol)
        }
        guard let port = AppIngress.uiPort(ports: ports, override: spec.spec.ingress?.hostPort),
              AppIngress.isPublishedPort(port, ports: ports)
        else {
            throw BarkVisorError.notFound("Workload has no published UI port")
        }
        let http = try AppIngress.loopbackURL(port: port, path: path, query: req.url.query)
        if websocket {
            return try HomeDeviceProxy.webSocketURL(from: http)
        }
        return http
    }

    private func memberTarget(
        hostId: String,
        path: String,
        query: String?,
        websocket: Bool,
    ) throws -> URL {
        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        guard let record = try store.record(forHostId: hostId) else {
            throw BarkVisorError.notFound("Device not found")
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Device has no reachable address")
        }
        let http = try HomeDeviceProxy.memberURL(
            host: agentHost,
            port: record.agentPort,
            path: path,
            query: query,
        )
        if websocket {
            return try HomeDeviceProxy.webSocketURL(from: http)
        }
        return http
    }

    private func send(
        req: Vapor.Request,
        url: URL,
        client: any HomeDeviceProxyClient,
        stripAuth: Bool,
    ) async throws -> Response {
        let body = try await HomeDevicesController.collectedBody(req)
        var headers: [(String, String)] = []
        for (name, value) in req.headers {
            headers.append((name, value))
        }
        if stripAuth {
            headers = AppIngress.stripForwardHeaders(headers)
        } else if let auth = req.headers.bearerAuthorization {
            headers = AppIngress.stripForwardHeaders(headers)
            headers.append(("Authorization", "Bearer \(auth.token)"))
        } else {
            headers = AppIngress.stripForwardHeaders(headers)
            if let token = req.cookies[AppIngress.cookieName]?.string, !token.isEmpty {
                headers.append(("Authorization", "Bearer \(token)"))
            }
        }
        if !headers.contains(where: { $0.0.lowercased() == APIContract.versionHeaderName.lowercased() }) {
            headers.append((APIContract.versionHeaderName, String(APIContract.version)))
        }
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
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .badGateway,
                reason: HomeDeviceProxyError.classify(error).localizedDescription,
            )
        }
        return HomeDevicesController.response(from: result)
    }
}
