import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct ComposeLogSnapshot: Content {
    let lines: [String]
    let tail: Int
}

struct ComposeLogLine: Content {
    let line: String
}

struct ApplicationOpsController: RouteCollection {
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let vms = routes.grouped("api", "vms")
        vms.get(":id", "logs", use: logs)
        vms.get(":id", "logs", "stream", use: streamLogs)
        vms.post(":id", "update", use: update)
        vms.post(":id", "check-update", use: checkUpdate)
    }

    @Sendable
    func logs(req: Request) async throws -> ComposeLogSnapshot {
        let vm = try await requireApplication(req)
        let tail = min(max(req.query[Int.self, at: "tail"] ?? 200, 1), 2_000)
        let text = (try? ApplicationLifecycleService.logs(vm: vm, tail: tail)) ?? ""
        return ComposeLogSnapshot(lines: ComposeLogHints.lines(from: text), tail: tail)
    }

    @Sendable
    func streamLogs(req: Request) async throws -> Response {
        let vm = try await requireApplication(req)
        let tail = min(max(req.query[Int.self, at: "tail"] ?? 200, 1), 2_000)
        let follow = try ApplicationLifecycleService.followLogs(vm: vm, tail: tail)
        let events = AsyncThrowingStream<ComposeLogLine, Error> { continuation in
            let task = Task {
                do {
                    for try await line in follow {
                        continuation.yield(ComposeLogLine(line: line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return SSEResponse.stream(from: events, keepaliveSeconds: 15)
    }

    @Sendable
    func update(req: Request) async throws -> Response {
        let vm = try await requireApplication(req)
        if vm.state != "running" {
            throw BarkVisorError.conflict("Application must be running to update images")
        }
        let taskID = ApplicationLifecycleService.taskID(forUpdate: vm.id)
        let db = req.db
        let workloadID = vm.id
        let submitted = await backgroundTasks.submit(taskID, kind: .appUpdate) {
            guard var live = try await db.read({ db in try VM.fetchOne(db, key: workloadID) }) else {
                throw BarkVisorError.notFound("Workload \(workloadID) not found")
            }
            try await ApplicationLifecycleService.updateImages(vm: &live, db: db) { value in
                Task {
                    await backgroundTasks.reportProgress(taskID, progress: value)
                }
            }
            return workloadID
        }
        AuditService.log(
            action: "vm.update-image",
            resourceType: "vm",
            resourceId: vm.id,
            resourceName: vm.name,
            req: req,
        )
        return try Response.json(TaskAcceptedResponse(taskID: submitted), status: .accepted)
    }

    @Sendable
    func checkUpdate(req: Request) async throws -> VMResponse {
        var vm = try await requireApplication(req)
        try await ApplicationLifecycleService.refreshImageFacts(vm: &vm, db: req.db)
        let published = await ApplicationLifecycleService.publishedUpdate(
            event: backgroundTasks.status(ApplicationLifecycleService.taskID(forUpdate: vm.id)),
        )
        return VMResponse(
            from: vm,
            updateTaskID: published.taskID,
            updateProgress: published.progress,
        )
    }

    private func requireApplication(_ req: Request) async throws -> VM {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        if !vm.isApplication {
            throw BarkVisorError.badRequest("logs and image updates are for Application workloads")
        }
        return vm
    }
}
