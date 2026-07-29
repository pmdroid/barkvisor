import BarkVisorCore
import Foundation
import GRDB
import Vapor

// MARK: - DTOs

struct TemplateResponse: Content {
    let id: String
    let slug: String
    let name: String
    let description: String?
    let category: String
    let icon: String
    let imageSlug: String
    let cpuCount: Int
    let memoryMB: Int
    let diskSizeGB: Int
    let portForwards: [PortForwardRule]?
    let networkMode: String
    let inputs: [TemplateInput]
    let userDataTemplate: String
    let isBuiltIn: Bool
    let repositoryId: String?

    init(from t: VMTemplate) {
        self.id = t.id
        self.slug = t.slug
        self.name = t.name
        self.description = t.description
        self.category = t.category
        self.icon = t.icon
        self.imageSlug = t.imageSlug
        self.cpuCount = t.cpuCount
        self.memoryMB = t.memoryMB
        self.diskSizeGB = t.diskSizeGB
        self.isBuiltIn = t.isBuiltIn
        self.networkMode = t.networkMode
        self.userDataTemplate = t.userDataTemplate
        self.repositoryId = t.repositoryId
        self.portForwards = JSONColumnCoding.decodeArray(PortForwardRule.self, from: t.portForwards)
        self.inputs = JSONColumnCoding.decodeArray(TemplateInput.self, from: t.inputs) ?? []
    }
}

struct DeployTemplateRequest: Content, Validatable {
    let templateId: String
    let vmName: String
    let inputs: [String: String]
    let cpuCount: Int?
    let memoryMB: Int?
    let diskSizeGB: Int?
    let networkId: String?

    static func validations(_ validations: inout Validations) {
        validations.add("templateId", as: String.self, is: !.empty)
        validations.add("vmName", as: String.self, is: .count(1 ... 128))
    }
}

struct DeployTemplateResponse: Content {
    let status: String // "downloading" | "provisioning" | "created"
    let imageId: String? // set when status == "downloading"
    let taskID: String? // set when status == "provisioning"
    let vm: VMResponse? // set when status == "created" | "provisioning"
}

// MARK: - Controller

struct TemplateController: RouteCollection {
    let vmManager: VMManager
    let imageDownloader: ImageDownloader
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let templates = routes.grouped("api", "templates")
        templates.get(use: list)
        templates.get(":id", use: get)
        templates.post("deploy", use: deploy)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [TemplateResponse] {
        let templates = try await req.db.read { db in
            try VMTemplate.fetchAll(db)
        }
        return templates.map { TemplateResponse(from: $0) }
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> TemplateResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let template = try await req.db.read({ db in
            try VMTemplate.fetchOne(db, key: id)
        })
        else {
            throw Abort(.notFound)
        }
        return TemplateResponse(from: template)
    }

    @Sendable
    func deploy(req: Vapor.Request) async throws -> Response {
        try DeployTemplateRequest.validate(content: req)
        let body = try req.content.decode(DeployTemplateRequest.self)

        let options = DeployOptions(
            templateId: body.templateId,
            vmName: body.vmName,
            inputs: body.inputs,
            cpuCount: body.cpuCount,
            memoryMB: body.memoryMB,
            diskSizeGB: body.diskSizeGB,
            networkId: body.networkId,
        )
        let result = try await TemplateDeployService.deploy(
            options: options,
            imageDownloader: imageDownloader,
            backgroundTasks: backgroundTasks,
            db: req.db,
        )

        switch result {
        case let .downloading(imageId):
            let body = DeployTemplateResponse(
                status: "downloading", imageId: imageId, taskID: nil, vm: nil,
            )
            return try Response.json(body, status: .ok)

        case let .created(vm):
            AuditService.log(
                action: "vm.deploy", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            let body = DeployTemplateResponse(
                status: "created", imageId: nil, taskID: nil, vm: VMResponse(from: vm),
            )
            return try Response.json(body, status: .ok)

        case let .provisioning(taskID, vm):
            AuditService.log(
                action: "vm.deploy", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            let body = DeployTemplateResponse(
                status: "provisioning", imageId: nil, taskID: taskID, vm: VMResponse(from: vm),
            )
            // 202 Accepted — client polls taskID (same pattern as POST /api/vms cloud-image create).
            return try Response.json(body, status: .accepted)
        }
    }
}
