import BarkVisorCore
import Foundation
import Vapor

struct TaskController: RouteCollection {
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let tasks = routes.grouped("api", "tasks")
        tasks.get(":taskID", use: getTask)
        tasks.get(":taskID", "stream", use: streamTask)
        tasks.delete(":taskID", use: cancelTask)
    }

    @Sendable
    func getTask(req: Vapor.Request) async throws -> Response {
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest)
        }
        guard let event = await backgroundTasks.status(taskID) else {
            throw Abort(.notFound, reason: "Task not found")
        }
        let data = try JSONEncoder().encode(event)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    @Sendable
    func streamTask(req: Vapor.Request) async throws -> Response {
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest)
        }

        let stream = await backgroundTasks.eventStream(taskID)
        return SSEResponse.stream(from: stream)
    }

    @Sendable
    func cancelTask(req: Vapor.Request) async throws -> HTTPStatus {
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest)
        }
        await backgroundTasks.cancel(taskID)
        return .noContent
    }
}
