import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct CreateAPIKeyRequest: Content, Validatable {
    let name: String
    let expiresIn: String?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty)
    }
}

struct APIKeyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let keys = routes.grouped("api", "auth", "keys")
        keys.post(use: create)
        keys.get(use: list)
        keys.delete(":id", use: revoke)
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> APIKeyCreateResponse {
        let authUser = try req.requireUser

        try CreateAPIKeyRequest.validate(content: req)
        let body = try req.content.decode(CreateAPIKeyRequest.self)
        let result = try await APIKeyService.create(
            name: body.name, expiresIn: body.expiresIn,
            userId: authUser.userId, db: req.db,
        )

        AuditService.log(
            action: "apikey.create", resourceType: "apikey", resourceId: result.apiKey.id,
            resourceName: result.apiKey.name, req: req,
        )
        return APIKeyCreateResponse(
            id: result.apiKey.id,
            name: result.apiKey.name,
            key: result.plaintext,
            keyPrefix: result.apiKey.keyPrefix,
            expiresAt: result.apiKey.expiresAt,
            createdAt: result.apiKey.createdAt,
        )
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [APIKeyResponse] {
        let authUser = try req.requireUser
        let keys = try await APIKeyService.list(userId: authUser.userId, db: req.db)
        return keys.map { key in
            APIKeyResponse(
                id: key.id,
                name: key.name,
                keyPrefix: key.keyPrefix,
                expiresAt: key.expiresAt,
                lastUsedAt: key.lastUsedAt,
                createdAt: key.createdAt,
            )
        }
    }

    @Sendable
    func revoke(req: Vapor.Request) async throws -> HTTPStatus {
        let authUser = try req.requireUser
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }

        let key = try await APIKeyService.revoke(id: id, userId: authUser.userId, db: req.db)
        AuditService.log(
            action: "apikey.revoke", resourceType: "apikey", resourceId: id, resourceName: key.name,
            req: req,
        )
        return .noContent
    }
}
