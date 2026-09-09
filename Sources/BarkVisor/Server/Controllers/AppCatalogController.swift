import BarkVisorCore
import GRDB
import Vapor

struct AppCatalogController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let catalog = routes.grouped("api", "catalog")
        catalog.get("apps", use: list)
        catalog.get("apps", ":id", use: get)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [AppCatalogEntryDTO] {
        let rows = try await req.db.read { db in
            try AppCatalogRecord.order(Column("name").asc).fetchAll(db)
        }
        return rows.map { $0.dto() }
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> AppCatalogEntryDTO {
        let id = try req.parameters.require("id")
        let row = try await req.db.read { db in
            try AppCatalogRecord.filter(Column("slug") == id).fetchOne(db)
        }
        guard let row else { throw Abort(.notFound) }
        return row.dto()
    }
}

extension AppCatalogEntryDTO: Content {}
