import BarkVisorCore
import Foundation
import Vapor

/// `POST /api/workloads/apply` and `GET /api/workloads/:id/spec` (PAS-80).
struct WorkloadApplyController: RouteCollection {
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let workloads = routes.grouped("api", "workloads")
        workloads.post("apply", use: apply)
        workloads.get(":id", "spec", use: getSpec)
    }

    @Sendable
    func apply(req: Vapor.Request) async throws -> WorkloadApplyResult {
        let dryRun = (try? req.query.get(Bool.self, at: "dryRun")) ?? false
        guard let buffer = req.body.data else {
            throw BarkVisorError.badRequest("Request body is required")
        }
        let data = Data(buffer: buffer)
        let contentType = req.headers.first(name: .contentType)
        let document = try WorkloadSpecDocument.parse(data: data, contentType: contentType)
        let result = try await WorkloadApplyService.apply(
            document: document,
            dryRun: dryRun,
            db: req.db,
            backgroundTasks: backgroundTasks,
        )
        let action = switch result.op {
        case .created: "workload.apply.create"
        case .updated: "workload.apply.update"
        case .unchanged: "workload.apply.unchanged"
        }
        if !dryRun {
            AuditService.log(
                action: action,
                resourceType: "vm",
                resourceId: result.id,
                req: req,
            )
        }
        return result
    }

    @Sendable
    func getSpec(req: Vapor.Request) async throws -> WorkloadSpec {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        return try await WorkloadApplyService.loadSpec(id: id, db: req.db)
    }
}
