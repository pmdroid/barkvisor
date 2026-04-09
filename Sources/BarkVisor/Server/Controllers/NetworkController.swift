import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct CreateNetworkRequest: Content, Validatable {
    let name: String
    let mode: String
    let bridge: String?
    let macAddress: String?
    let dnsServer: String?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty)
        validations.add("mode", as: String.self, is: .in("nat", "bridged"))
    }
}

struct UpdateNetworkRequest: Content {
    let name: String?
    let mode: String?
    let bridge: String?
    let macAddress: String?
    let dnsServer: String?
}

struct NetworkController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let networks = routes.grouped("api", "networks")
        networks.get(use: list)
        networks.post(use: create)
        networks.patch(":id", use: update)
        networks.delete(":id", use: delete)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [Network] {
        let (limit, offset) = req.pagination()
        return try await req.db.read { db in try Network.limit(limit, offset: offset).fetchAll(db) }
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> Network {
        try CreateNetworkRequest.validate(content: req)
        let body = try req.content.decode(CreateNetworkRequest.self)
        let network = try await NetworkService.create(
            CreateNetworkParams(
                name: body.name, mode: body.mode, bridge: body.bridge,
                macAddress: body.macAddress, dnsServer: body.dnsServer,
            ),
            db: req.db,
        )
        AuditService.log(
            action: "network.create", resourceType: "network", resourceId: network.id,
            resourceName: network.name, req: req,
        )
        return network
    }

    @Sendable
    func update(req: Vapor.Request) async throws -> Network {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try req.content.decode(UpdateNetworkRequest.self)
        let network = try await NetworkService.update(
            UpdateNetworkParams(
                id: id, name: body.name, mode: body.mode, bridge: body.bridge,
                macAddress: body.macAddress, dnsServer: body.dnsServer,
            ),
            db: req.db,
        )
        AuditService.log(
            action: "network.update", resourceType: "network", resourceId: network.id,
            resourceName: network.name, req: req,
        )
        return network
    }

    @Sendable
    func delete(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let network = try await NetworkService.delete(id: id, db: req.db)
        AuditService.log(
            action: "network.delete", resourceType: "network", resourceId: id,
            resourceName: network?.name, req: req,
        )
        return .noContent
    }
}
