import BarkVisorCore
import Foundation
import Vapor

/// Home device registry + member proxy (PAS-34).
///
/// JWT on 7777. Listing is local-only. Proxying a member uses mTLS on
/// the agent port; this Device stays up if the member does not (PAS-47).
struct HomeDevicesController: RouteCollection {
    var devices: DeviceRegistry?
    var mtlsClient: (any HomeDeviceProxyClient)?
    var localClient: any HomeDeviceProxyClient
    var dataDir: URL
    var hostId: String
    var localPort: Int

    init(
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
        localPort: Int = Config.port,
        devices: DeviceRegistry? = nil,
        mtlsClient: (any HomeDeviceProxyClient)? = nil,
        localClient: any HomeDeviceProxyClient = LocalHostProxyClient(),
    ) {
        self.dataDir = dataDir
        self.hostId = hostId
        self.localPort = localPort
        self.devices = devices
        self.mtlsClient = mtlsClient
        self.localClient = localClient
    }

    func boot(routes: any RoutesBuilder) throws {
        let home = routes.grouped("api", "home")
        home.get("devices", use: list)
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE] {
            home.on(method, "devices", ":id", "v1", "**", use: proxy)
        }
    }

    @Sendable
    func list(req: Vapor.Request) throws -> HomeDeviceList {
        _ = try req.requireUser
        return HomeDeviceDirectory.list(
            dataDir: dataDir,
            hostId: hostId,
            displayName: ProcessInfo.processInfo.hostName,
            devices: devices,
        )
    }

    @Sendable
    func proxy(req: Vapor.Request) async throws -> Response {
        _ = try req.requireUser
        let id = try req.parameters.require("id")
        let remainder = req.parameters.getCatchall()
        let path = try HomeDeviceProxy.memberAPIPath(components: remainder)
        let query = req.url.query

        if id == hostId {
            let url = try HomeDeviceProxy.localURL(port: localPort, path: path, query: query)
            return try await forward(req: req, url: url, client: localClient)
        }

        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        let record: DeviceRecord
        do {
            guard let found = try store.record(forHostId: id) else {
                throw BarkVisorError.notFound("Device not found")
            }
            record = found
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .serviceUnavailable,
                reason: "Device registry is unavailable; local runtime continues",
            )
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Device has no reachable address")
        }
        let url = try HomeDeviceProxy.memberURL(
            host: agentHost,
            port: record.agentPort,
            path: path,
            query: query,
        )
        let client: any HomeDeviceProxyClient
        if let mtlsClient {
            client = mtlsClient
        } else {
            do {
                client = try HomeDevicesMTLS.client(dataDir: dataDir, hostId: hostId)
            } catch {
                throw Abort(
                    .serviceUnavailable,
                    reason: "This Device cannot reach members yet; local runtime continues",
                )
            }
        }
        return try await forward(req: req, url: url, client: client)
    }

    private func forward(
        req: Vapor.Request,
        url: URL,
        client: any HomeDeviceProxyClient,
    ) async throws -> Response {
        let body = try await Self.collectedBody(req)
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
                reason: "Device is unreachable: \(error.localizedDescription)",
            )
        }
        return Self.response(from: result)
    }

    static func collectedBody(_ req: Vapor.Request) async throws -> Data? {
        let buffer = try await req.body.collect(max: HomeDeviceProxy.maxBodyBytes).get()
        return buffer.map { Data($0.readableBytesView) }
    }

    static func response(from result: HomeDeviceProxyResponse) -> Response {
        let hopByHop: Set = [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailers", "transfer-encoding", "upgrade", "host",
        ]
        var headers = HTTPHeaders()
        for (name, value) in result.headers {
            if hopByHop.contains(name.lowercased()) { continue }
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(
            name: APIContract.versionHeaderName,
            value: String(APIContract.version),
        )
        return Response(
            status: .init(statusCode: result.status),
            headers: headers,
            body: .init(data: result.body),
        )
    }
}
