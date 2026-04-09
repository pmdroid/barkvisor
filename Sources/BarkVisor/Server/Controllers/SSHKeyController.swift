import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct CreateSSHKeyRequest: Content, Validatable {
    let name: String
    let publicKey: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty)
        validations.add("publicKey", as: String.self, is: !.empty)
    }
}

struct SSHKeyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let keys = routes.grouped("api", "ssh-keys")
        keys.get(use: list)
        keys.post(use: create)
        keys.post(":id", "default", use: setDefault)
        keys.delete(":id", use: delete)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [SSHKey] {
        try await SSHKeyService.list(db: req.db)
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> SSHKey {
        try CreateSSHKeyRequest.validate(content: req)
        let body = try req.content.decode(CreateSSHKeyRequest.self)
        let sshKey = try await SSHKeyService.create(
            name: body.name, publicKey: body.publicKey, db: req.db,
        )
        AuditService.log(
            action: "ssh-key.create", resourceType: "ssh-key", resourceId: sshKey.id,
            resourceName: sshKey.name, req: req,
        )
        return sshKey
    }

    @Sendable
    func setDefault(req: Vapor.Request) async throws -> SSHKey {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing SSH key ID")
        }
        return try await SSHKeyService.setDefault(id: id, db: req.db)
    }

    @Sendable
    func delete(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing SSH key ID")
        }
        try await SSHKeyService.delete(id: id, db: req.db)
        AuditService.log(action: "ssh-key.delete", resourceType: "ssh-key", resourceId: id, req: req)
        return .noContent
    }
}
