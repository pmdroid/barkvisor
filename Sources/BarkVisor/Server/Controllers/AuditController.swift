import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct AuditLogResponse: Content {
    let entries: [AuditEntry]
    let total: Int
}

struct AuditController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "audit-log", use: list)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> AuditLogResponse {
        let (clampedLimit, offset) = req.pagination(defaultLimit: 50)
        let actionFilter = req.query[String.self, at: "action"]
        let resourceTypeFilter = req.query[String.self, at: "resourceType"]

        let (entries, total) = try await req.db.read { db -> ([AuditEntry], Int) in
            var query = AuditEntry.all()

            if let actionFilter {
                query = query.filter(AuditEntry.Columns.action == actionFilter)
            }
            if let resourceTypeFilter {
                query = query.filter(AuditEntry.Columns.resourceType == resourceTypeFilter)
            }

            let total = try query.fetchCount(db)
            let results =
                try query
                    .order(AuditEntry.Columns.id.desc)
                    .limit(clampedLimit, offset: offset)
                    .fetchAll(db)

            return (results, total)
        }

        return AuditLogResponse(entries: entries, total: total)
    }
}
