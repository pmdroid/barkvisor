import Foundation
import GRDB

public enum DeployResult {
    case downloading(imageId: String)
    /// Disk clone / cloud-init still running (async task).
    case provisioning(taskID: String, vm: VM)
    /// Immediate create (no async provision) — rare for templates (cloud images).
    case created(VM)
}

public struct DeployRecipeImage: Codable, Sendable {
    public let downloadUrl: String
    public let arch: String
    public let imageType: String
    public let sha256: String?
    public let sha512: String?
    public let name: String?
    public let slug: String?

    public init(
        downloadUrl: String,
        arch: String,
        imageType: String,
        sha256: String? = nil,
        sha512: String? = nil,
        name: String? = nil,
        slug: String? = nil,
    ) {
        self.downloadUrl = downloadUrl
        self.arch = arch
        self.imageType = imageType
        self.sha256 = sha256
        self.sha512 = sha512
        self.name = name
        self.slug = slug
    }
}

public struct DeployRecipe: Codable, Sendable {
    public let name: String?
    public let slug: String?
    public let inputs: [TemplateInput]
    public let userDataTemplate: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeGB: Int
    public let networkMode: String?
    public let portForwards: [PortForwardRule]?
    public let architectures: [String]?
    public let minMemoryMB: Int?
    public let requiredFeatures: [String]?
    public let image: DeployRecipeImage

    public init(
        name: String? = nil,
        slug: String? = nil,
        inputs: [TemplateInput],
        userDataTemplate: String,
        cpuCount: Int,
        memoryMB: Int,
        diskSizeGB: Int,
        networkMode: String? = nil,
        portForwards: [PortForwardRule]? = nil,
        architectures: [String]? = nil,
        minMemoryMB: Int? = nil,
        requiredFeatures: [String]? = nil,
        image: DeployRecipeImage,
    ) {
        self.name = name
        self.slug = slug
        self.inputs = inputs
        self.userDataTemplate = userDataTemplate
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.networkMode = networkMode
        self.portForwards = portForwards
        self.architectures = architectures
        self.minMemoryMB = minMemoryMB
        self.requiredFeatures = requiredFeatures
        self.image = image
    }
}

public struct DeployOptions {
    public let templateId: String
    public let vmName: String
    public let inputs: [String: String]
    public let cpuCount: Int?
    public let memoryMB: Int?
    public let diskSizeGB: Int?
    public let networkId: String?
    public let recipe: DeployRecipe?

    public init(
        templateId: String,
        vmName: String,
        inputs: [String: String],
        cpuCount: Int? = nil,
        memoryMB: Int? = nil,
        diskSizeGB: Int? = nil,
        networkId: String? = nil,
        recipe: DeployRecipe? = nil,
    ) {
        self.templateId = templateId
        self.vmName = vmName
        self.inputs = inputs
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.networkId = networkId
        self.recipe = recipe
    }
}

public enum TemplateDeployService {
    /// Deploy a VM from a template via the shared `VMLifecycleService.createVM` path.
    public static func deploy(
        options: DeployOptions,
        imageDownloader: any ImageDownloadStarting,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
    ) async throws -> DeployResult {
        let inventory = HostInventoryService.snapshot()
        let template: VMTemplate
        let repoImage: RepositoryImage
        if let recipe = options.recipe {
            template = try templateFromRecipe(recipe, id: options.templateId)
            try validateInputs(template: template, inputs: options.inputs)
            try enforceCompatibility(template: template, inventory: inventory, options: options)
            try PlatformCapabilities.requireCompatibleGuestArch(recipe.image.arch)
            repoImage = repositoryImage(from: recipe)
        } else {
            template = try await fetchTemplate(id: options.templateId, db: db)
            try validateInputs(template: template, inputs: options.inputs)
            try enforceCompatibility(template: template, inventory: inventory, options: options)
            repoImage = try await resolveRepoImage(
                template: template, hostArch: inventory.platform.arch, db: db,
            )
            // PAS-48: reject before downloading a multi-hundred-MB foreign-arch image.
            // createVM also guards via validateCreateVMInputs; this is the early gate.
            try PlatformCapabilities.requireCompatibleGuestArch(repoImage.arch)
        }

        let checksum = ExpectedChecksum.catalog(from: repoImage)
        let localImage = try await db.read { db in
            try ImageService.readyImage(
                sourceUrl: repoImage.downloadUrl, expectedChecksum: checksum, db: db,
            )
        }

        if localImage == nil {
            return try await startOrDetectDownload(
                repoImage: repoImage, imageDownloader: imageDownloader, db: db,
            )
        }

        guard let localImage else {
            throw BarkVisorError.internalError("Local image unexpectedly nil")
        }
        return try await createViaLifecycle(
            options: options,
            template: template,
            localImage: localImage,
            backgroundTasks: backgroundTasks,
            db: db,
        )
    }

    // MARK: - Private

    private static func fetchTemplate(
        id: String, db: DatabasePool,
    ) async throws -> VMTemplate {
        guard let template = try await db.read({ db in
            try VMTemplate.fetchOne(db, key: id)
        })
        else {
            throw BarkVisorError.notFound("Template not found")
        }
        return template
    }

    private static func templateFromRecipe(_ recipe: DeployRecipe, id: String) throws -> VMTemplate {
        let url = recipe.image.downloadUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw BarkVisorError.badRequest("Recipe image downloadUrl is required")
        }
        let now = iso8601.string(from: Date())
        let inputsJSON = JSONColumnCoding.encode(recipe.inputs) ?? "[]"
        let arches = recipe.architectures ?? [recipe.image.arch]
        var imageByArch: [String: String] = [:]
        if let slug = recipe.image.slug, !slug.isEmpty {
            imageByArch[PlatformCapabilities.normalizedArch(recipe.image.arch)] = slug
        }
        return VMTemplate(
            id: id,
            slug: recipe.slug ?? "recipe",
            name: recipe.name ?? "Template",
            description: nil,
            category: "general",
            icon: "terminal",
            imageSlug: recipe.image.slug ?? "",
            cpuCount: recipe.cpuCount,
            memoryMB: recipe.memoryMB,
            diskSizeGB: recipe.diskSizeGB,
            portForwards: JSONColumnCoding.encode(recipe.portForwards),
            networkMode: recipe.networkMode ?? NetworkMode.nat.rawValue,
            inputs: inputsJSON,
            userDataTemplate: recipe.userDataTemplate,
            isBuiltIn: false,
            repositoryId: nil,
            createdAt: now,
            updatedAt: now,
            architecturesJson: JSONColumnCoding.encode(arches),
            minMemoryMB: recipe.minMemoryMB,
            requiredFeaturesJson: JSONColumnCoding.encodeArrayOrNil(recipe.requiredFeatures),
            imageByArchJson: imageByArch.isEmpty ? nil : JSONColumnCoding.encode(imageByArch),
        )
    }

    private static func repositoryImage(from recipe: DeployRecipe) -> RepositoryImage {
        RepositoryImage(
            id: UUID().uuidString,
            repositoryId: "recipe",
            slug: recipe.image.slug ?? recipe.slug ?? "recipe",
            name: recipe.image.name ?? recipe.name ?? "Image",
            description: nil,
            imageType: recipe.image.imageType,
            arch: recipe.image.arch,
            version: nil,
            downloadUrl: recipe.image.downloadUrl,
            sizeBytes: nil,
            sha256: recipe.image.sha256,
            sha512: recipe.image.sha512,
        )
    }

    private static func validateInputs(
        template: VMTemplate, inputs: [String: String],
    ) throws {
        guard let inputDefs = try? JSONDecoder().decode(
            [TemplateInput].self,
            from: Data(template.inputs.utf8),
        )
        else {
            throw BarkVisorError.internalError("Invalid template inputs")
        }

        for input in inputDefs {
            guard let value = inputs[input.id], !value.isEmpty else {
                if input.required {
                    throw BarkVisorError.badRequest("Missing required input: \(input.label)")
                }
                continue
            }
            if let minLen = input.minLength, value.count < minLen {
                throw BarkVisorError.badRequest(
                    "\(input.label) must be at least \(minLen) characters",
                )
            }
            if let maxLen = input.maxLength, value.count > maxLen {
                throw BarkVisorError.badRequest(
                    "\(input.label) must be at most \(maxLen) characters",
                )
            }
        }
    }

    private static func enforceCompatibility(
        template: VMTemplate, inventory: HostInventory, options: DeployOptions,
    ) throws {
        let report = TemplateCompatibility.evaluate(
            template: template,
            host: inventory,
            requestedMemoryMB: options.memoryMB,
        )
        guard report.compatible else {
            let message = report.reasons.first?.message
                ?? "Template is not compatible with this host."
            throw BarkVisorError.badRequest(message)
        }
    }

    private static func resolveRepoImage(
        template: VMTemplate, hostArch: String, db: DatabasePool,
    ) async throws -> RepositoryImage {
        guard let slug = template.resolvedImageSlug(forArch: hostArch) else {
            throw BarkVisorError.badRequest(
                "Template '\(template.slug)' has no image for host architecture \(PlatformCapabilities.normalizedArch(hostArch)).",
            )
        }
        let repoImage: RepositoryImage? = try await db.read { db in
            if let repoId = template.repositoryId {
                if let img =
                    try RepositoryImage
                        .filter(Column("repositoryId") == repoId)
                        .filter(Column("slug") == slug)
                        .fetchOne(db) {
                    return img
                }
            }
            return try RepositoryImage.filter(Column("slug") == slug).fetchOne(db)
        }
        guard let repoImage else {
            throw BarkVisorError.badRequest(
                "Image \(slug) not found in any repository. Please sync your repositories first.",
            )
        }
        return repoImage
    }

    private static func startOrDetectDownload(
        repoImage: RepositoryImage,
        imageDownloader: any ImageDownloadStarting,
        db: DatabasePool,
    ) async throws -> DeployResult {
        guard let sourceURL = URL(string: repoImage.downloadUrl),
              let scheme = sourceURL.scheme?.lowercased(),
              Config.allowedURLSchemes.contains(scheme)
        else {
            throw BarkVisorError.badRequest("Invalid download URL for image")
        }
        let claim = try await ImageService.startOrDetectCatalogDownload(
            repoImage: repoImage,
            sourceURL: sourceURL,
            checksum: .catalog(from: repoImage),
            downloader: imageDownloader,
            db: db,
        )
        return .downloading(imageId: claim.image.id)
    }

    /// Build `CreateVMParams` and delegate to the shared create pipeline (async disk clone).
    private static func createViaLifecycle(
        options: DeployOptions,
        template: VMTemplate,
        localImage: VMImage,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
    ) async throws -> DeployResult {
        let renderedUserData = try TemplateRenderer.render(
            template: template.userDataTemplate,
            inputs: options.inputs,
        )

        let vmType = GuestProfiles.defaultLinuxID(forImageArch: localImage.arch)
        let cpu = options.cpuCount ?? template.cpuCount
        let mem = options.memoryMB ?? template.memoryMB
        let disk = options.diskSizeGB ?? template.diskSizeGB

        let resolvedNetworkId = try await resolveNetwork(
            requestedId: options.networkId, templateMode: template.networkMode,
            vmName: options.vmName, db: db,
        )

        let portForwards = JSONColumnCoding.decodeArray(
            PortForwardRule.self, from: template.portForwards,
        )

        let sshKeys =
            options.inputs["ssh_keys"]?
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty } ?? []

        // Strip optional leading cloud-config header; CloudInitService adds it when generating ISO.
        var userData = renderedUserData
        if userData.hasPrefix("#cloud-config\n") {
            userData = String(userData.dropFirst("#cloud-config\n".count))
        }
        if !userData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try CloudInitService.validateUserData(userData, allowCatalogIdentityKeys: true)
        }

        let isISO = localImage.imageType == "iso"
        let cloudInit: CloudInitConfig? = if isISO {
            nil
        } else {
            CloudInitConfig(
                sshAuthorizedKeys: sshKeys.isEmpty ? nil : sshKeys,
                userData: userData.isEmpty ? nil : userData,
            )
        }

        let params = CreateVMParams(
            name: options.vmName,
            vmType: vmType,
            cpuCount: cpu,
            memoryMB: mem,
            diskSizeGB: disk,
            isoId: isISO ? localImage.id : nil,
            cloudImageId: isISO ? nil : localImage.id,
            cloudInit: cloudInit,
            networkId: resolvedNetworkId,
            portForwards: portForwards,
            description: "Deployed from template: \(template.name)",
            uefi: true,
            tpmEnabled: false,
            allowCatalogIdentityKeys: true,
        )

        let result = try await VMLifecycleService.createVM(
            params: params,
            db: db,
            backgroundTasks: backgroundTasks,
        )

        switch result {
        case let .created(vm):
            return .created(vm)
        case let .provisioning(taskID, vm):
            return .provisioning(taskID: taskID, vm: vm)
        }
    }

    private static func resolveNetwork(
        requestedId: String?, templateMode: String, vmName: String, db: DatabasePool,
    ) async throws -> String? {
        if let userNetId = requestedId {
            guard try await db.read({ db in
                try Network.fetchOne(db, key: userNetId)
            }) != nil
            else {
                throw BarkVisorError.badRequest("Network not found")
            }
            return userNetId
        }

        let mode = try NetworkCapability.parse(
            templateMode.isEmpty ? NetworkMode.nat.rawValue : templateMode,
        )
        try NetworkCapability.requireMode(mode.rawValue)

        if mode == .isolated {
            if let existing = try await db.read({ db in
                try Network.filter(Column("mode") == NetworkMode.isolated.rawValue).fetchOne(db)
            }) {
                return existing.id
            }
            return try await NetworkService.create(
                CreateNetworkParams(
                    name: "Isolated",
                    mode: NetworkMode.isolated.rawValue,
                    bridge: nil,
                    macAddress: nil,
                    dnsServer: nil,
                ),
                db: db,
            ).id
        } else if mode == .bridged {
            try PlatformCapabilities.requireBridgedNetworking()
            let records = try await db.read { db in
                try BridgeRecord.filter(Column("status") == "active").fetchAll(db)
            }
            let interface = try HostBridgeFactsService.activeBridgedInterface(records: records)
            return try await NetworkService.ensureBridgedNetwork(for: interface, db: db).id
        } else {
            let defaultNAT = try await db.read { db in
                try Network.filter(Column("mode") == "nat" && Column("isDefault") == true).fetchOne(db)
                    ?? Network.filter(Column("mode") == "nat").fetchOne(db)
            }
            return defaultNAT?.id
        }
    }
}
