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
    let architectures: [String]
    let imageByArch: [String: String]
    let minMemoryMB: Int?
    let requiredFeatures: [String]
    let resolvedImageSlug: String?
    let compatible: Bool
    let catalogImages: [TemplateCatalogImageRef]

    init(
        from t: VMTemplate,
        host: HostInventory? = nil,
        catalogImages: [TemplateCatalogImageRef] = [],
    ) {
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
        self.architectures = t.declaredArchitectures
        self.imageByArch = t.imageByArch
        self.minMemoryMB = t.minMemoryMB
        self.requiredFeatures = t.requiredFeatures
        self.catalogImages = catalogImages
        if let host {
            // Same checks as dry-run/deploy: arch, image, requiredFeatures, minMemoryMB.
            let report = TemplateCompatibility.evaluate(template: t, host: host)
            self.resolvedImageSlug = report.resolvedImageSlug
            self.compatible = report.compatible
        } else {
            self.resolvedImageSlug = nil
            self.compatible = true
        }
    }
}

struct TemplateCatalogImageRef: Content {
    let slug: String
    let name: String
    let imageType: String
    let arch: String
    let downloadUrl: String
    let sha256: String?
    let sha512: String?

    init(from img: RepositoryImage) {
        self.slug = img.slug
        self.name = img.name
        self.imageType = img.imageType
        self.arch = img.arch
        self.downloadUrl = img.downloadUrl
        self.sha256 = img.sha256
        self.sha512 = img.sha512
    }
}

extension DeployRecipe: Content {}
extension DeployRecipeImage: Content {}

struct DeployTemplateRequest: Content, Validatable {
    let templateId: String
    let vmName: String
    let inputs: [String: String]
    let cpuCount: Int?
    let memoryMB: Int?
    let diskSizeGB: Int?
    let networkId: String?
    let recipe: DeployRecipe?

    static func validations(_ validations: inout Validations) {
        validations.add("templateId", as: String.self, is: !.empty)
        validations.add("vmName", as: String.self, is: .count(1 ... 128))
    }
}

struct DeployTemplateResponse: Content {
    let status: String // "downloading" | "provisioning" | "created"
    let imageId: String? // set when status == "downloading"
    let taskID: String? // set when status == "provisioning"
    let vm: VMResponse?
}

struct DeployDryRunRequest: Content {
    var targetHostId: String?
    var memoryMB: Int?
}

// MARK: - Controller

struct TemplateController: RouteCollection {
    let vmManager: VMManager
    let imageDownloader: ImageDownloader
    let backgroundTasks: BackgroundTaskManager
    let syncService: RepositorySyncService

    func boot(routes: any RoutesBuilder) throws {
        let templates = routes.grouped("api", "templates")
        templates.get(use: list)
        templates.get(":id", use: get)
        templates.post(":id", "deploy", "dry-run", use: dryRun)
        templates.post("deploy", use: deploy)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [TemplateResponse] {
        let inventory = HostInventoryService.snapshot()
        try TemplateCompatibility.requireLocalHost(
            requestedHostId: req.query[String.self, at: "hostId"],
            inventory: inventory,
        )
        let filterArch = req.query[String.self, at: "arch"]
            ?? (req.query[String.self, at: "hostId"] != nil ? inventory.platform.arch : nil)

        let (loaded, repoImages) = try await req.db.read { db -> ([VMTemplate], [RepositoryImage]) in
            try (VMTemplate.fetchAll(db), RepositoryImage.fetchAll(db))
        }
        var templates = loaded
        if let filterArch {
            templates = templates.filter {
                TemplateArchitecture.supports(
                    architectures: $0.declaredArchitectures, arch: filterArch,
                )
            }
        }
        return templates.map {
            TemplateResponse(
                from: $0,
                host: inventory,
                catalogImages: catalogImages(for: $0, from: repoImages),
            )
        }
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> TemplateResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let row = try await req.db.read { db -> (VMTemplate, [RepositoryImage])? in
            guard let template = try VMTemplate.fetchOne(db, key: id) else { return nil }
            let images = try RepositoryImage.fetchAll(db)
            return (template, images)
        }
        guard let (template, repoImages) = row else {
            throw Abort(.notFound)
        }
        return TemplateResponse(
            from: template,
            host: HostInventoryService.snapshot(),
            catalogImages: catalogImages(for: template, from: repoImages),
        )
    }

    @Sendable
    func dryRun(req: Vapor.Request) async throws -> TemplateCompatibilityReport {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let template = try await req.db.read({ db in
            try VMTemplate.fetchOne(db, key: id)
        })
        else {
            throw Abort(.notFound)
        }
        let body = try? req.content.decode(DeployDryRunRequest.self)
        let inventory = HostInventoryService.snapshot()
        try TemplateCompatibility.requireLocalHost(
            requestedHostId: body?.targetHostId, inventory: inventory,
        )
        return TemplateCompatibility.evaluate(
            template: template, host: inventory, requestedMemoryMB: body?.memoryMB,
        )
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
            recipe: body.recipe,
        )
        let result = try await TemplateDeployService.deploy(
            options: options,
            imageDownloader: imageDownloader,
            backgroundTasks: backgroundTasks,
            db: req.db,
            catalogSync: syncService,
        )

        switch result {
        case let .downloading(imageId, vm):
            AuditService.log(
                action: "vm.deploy", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            let image = try await req.db.read { db in try VMImage.fetchOne(db, key: imageId) }
            let percent = await ImageTransferPercent.current(
                status: image?.status,
                lastProgress: imageDownloader.lastProgress(imageID: imageId),
            )
            let body = DeployTemplateResponse(
                status: "downloading",
                imageId: imageId,
                taskID: nil,
                vm: VMResponse(from: vm, pendingImageId: imageId, downloadPercent: percent),
            )
            return try Response.json(body, status: .accepted)

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

private func catalogImages(
    for template: VMTemplate, from all: [RepositoryImage],
) -> [TemplateCatalogImageRef] {
    var slugs = Set<String>()
    if !template.imageSlug.isEmpty {
        slugs.insert(template.imageSlug)
    }
    for slug in template.imageByArch.values where !slug.isEmpty {
        slugs.insert(slug)
    }
    let matches = all.filter { slugs.contains($0.slug) }
    let scoped: [RepositoryImage]
    if let repoId = template.repositoryId {
        let inRepo = matches.filter { $0.repositoryId == repoId }
        scoped = inRepo.isEmpty ? matches : inRepo
    } else {
        scoped = matches
    }
    var seen = Set<String>()
    var out: [TemplateCatalogImageRef] = []
    for img in scoped {
        let arch = PlatformCapabilities.normalizedArch(img.arch)
        if arch.isEmpty || seen.contains(arch) { continue }
        seen.insert(arch)
        out.append(TemplateCatalogImageRef(from: img))
    }
    return out
}
