import BarkVisorCore
import GRDB
import Vapor

struct AgentCatalogController: RouteCollection {
    let database: DatabasePool
    let dataDir: URL

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "catalogs", "applied", ":repoType", use: get)
        routes.put("api", "catalogs", "applied", ":repoType", use: put)
    }

    @Sendable
    func get(req: Vapor.Request) throws -> Response {
        _ = try requirePeer(req)
        let repoType = try Self.requireRepoType(req)
        let store = LastGoodCatalogStore(directory: dataDir)
        guard let data = store.load(repoType: repoType), !data.isEmpty else {
            throw Abort(.notFound)
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    @Sendable
    func put(req: Vapor.Request) async throws -> HTTPStatus {
        _ = try requirePeer(req)
        let repoType = try Self.requireRepoType(req)
        let collected = try await req.body.collect(max: HomeDeviceProxy.maxBodyBytes).get()
        guard let buffer = collected else {
            throw Abort(.badRequest, reason: "Catalog body is required")
        }
        let data = Data(buffer.readableBytesView)
        guard !data.isEmpty else {
            throw Abort(.badRequest, reason: "Catalog body is required")
        }
        let store = LastGoodCatalogStore(directory: dataDir)
        let sync = RepositorySyncService(
            dbPool: database,
            lastGood: store,
            memberCatalogFetchDisabled: true,
        )
        try await sync.applyCatalogBytes(data, repoType: repoType)
        return .noContent
    }

    private func requirePeer(_ req: Vapor.Request) throws -> AgentPeerIdentity {
        guard let peer = req.mtlsPeer else {
            throw Abort(.unauthorized, reason: "Client certificate required")
        }
        return peer
    }

    private static func requireRepoType(_ req: Vapor.Request) throws -> String {
        let repoType = try req.parameters.require("repoType")
        guard HomeCatalogOrigin.repoTypes.contains(repoType) else {
            throw Abort(.badRequest, reason: "repoType must be images or templates")
        }
        return repoType
    }
}
