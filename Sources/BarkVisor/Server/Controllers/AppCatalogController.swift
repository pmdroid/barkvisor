import BarkVisorCore
import GRDB
import Vapor

struct AppCatalogController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let catalog = routes.grouped("api", "catalog")
        catalog.get("apps", use: list)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [AppCatalogEntryDTO] {
        let rows = try await req.db.read { db in
            try AppCatalogRecord.order(Column("name").asc).fetchAll(db)
        }
        return rows.map { $0.dto() }
    }
}

extension AppCatalogEntryDTO: Content {}
