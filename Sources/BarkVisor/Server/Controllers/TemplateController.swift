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
    let status: String // "downloading" | "created"
    let imageId: String? // set when status == "downloading"
    let vm: VMResponse? // set when status == "created"
}

// MARK: - Controller

struct TemplateController: RouteCollection {
    let vmManager: VMManager
    let imageDownloader: ImageDownloader

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
    func deploy(req: Vapor.Request) async throws -> DeployTemplateResponse {
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
            vmManager: vmManager,
            imageDownloader: imageDownloader,
            db: req.db,
        )

        switch result {
        case let .downloading(imageId):
            return DeployTemplateResponse(status: "downloading", imageId: imageId, vm: nil)
        case let .created(vm):
            AuditService.log(
                action: "vm.deploy", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            return DeployTemplateResponse(status: "created", imageId: nil, vm: VMResponse(from: vm))
        }
    }
}
