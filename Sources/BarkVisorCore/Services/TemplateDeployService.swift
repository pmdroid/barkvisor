import Foundation
import GRDB

public enum DeployResult {
    case downloading(imageId: String, vm: VM)
    case provisioning(taskID: String, vm: VM)
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
    public let sizeBytes: Int64?

    public init(
        downloadUrl: String,
        arch: String,
        imageType: String,
        sha256: String? = nil,
        sha512: String? = nil,
        name: String? = nil,
        slug: String? = nil,
        sizeBytes: Int64? = nil,
    ) {
        self.downloadUrl = downloadUrl
        self.arch = arch
        self.imageType = imageType
        self.sha256 = sha256
        self.sha512 = sha512
        self.name = name
        self.slug = slug
        self.sizeBytes = sizeBytes
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

public struct DeployOptions: Codable, Sendable {
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

        if let localImage {
            return try await createViaLifecycle(
                options: options,
                template: template,
                localImage: localImage,
                vmID: nil,
                backgroundTasks: backgroundTasks,
                db: db,
            )
        }

        let claim = try await claimCatalogDownload(repoImage: repoImage, db: db)
        if let existing = try await existingPending(
            vmName: options.vmName, imageId: claim.image.id, db: db,
        ) {
            await submitFinishTask(
                vm: existing,
                imageId: claim.image.id,
                imageDownloader: imageDownloader,
                backgroundTasks: backgroundTasks,
                db: db,
            )
            return .downloading(imageId: claim.image.id, vm: existing)
        }

        let vm = try await insertPlaceholder(
            options: options,
            template: template,
            repoImage: repoImage,
            imageId: claim.image.id,
            db: db,
        )
        do {
            try await ImageService.requireCatalogLibrarySpace(
                sizeBytes: repoImage.sizeBytes, db: db,
            )
            _ = try await startClaimedDownload(
                claim: claim,
                repoImage: repoImage,
                imageDownloader: imageDownloader,
                db: db,
            )
        } catch {
            let message = (error as? BarkVisorError)?.sanitizedDescription
                ?? error.localizedDescription
            if case .started = claim {
                await LibraryAcquire.markFailed(
                    imageId: claim.image.id,
                    message: message,
                    db: db,
                )
            }
            await failPending(vmID: vm.id, message: message, db: db)
            throw error
        }
        await submitFinishTask(
            vm: vm,
            imageId: claim.image.id,
            imageDownloader: imageDownloader,
            backgroundTasks: backgroundTasks,
            db: db,
        )
        return .downloading(imageId: claim.image.id, vm: vm)
    }

    public static func deployTaskID(vmID: String) -> String {
        "template-deploy:\(vmID)"
    }

    public static func resumePending(
        imageDownloader: any ImageDownloadStarting,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
    ) async {
        let rows: [PendingDeploy]
        do {
            rows = try await db.read { db in
                try PendingDeploy.fetchAll(db)
            }
        } catch {
            Log.vm.error("Failed to load pending template deploys: \(error.localizedDescription)")
            return
        }
        for row in rows {
            let vm: VM?
            do {
                vm = try await db.read { db in try VM.fetchOne(db, key: row.vmId) }
            } catch {
                continue
            }
            guard let vm else { continue }
            await submitFinishTask(
                vm: vm,
                imageId: row.imageId,
                imageDownloader: imageDownloader,
                backgroundTasks: backgroundTasks,
                db: db,
            )
        }
    }

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
            sizeBytes: recipe.image.sizeBytes,
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

    private static func catalogSourceURL(_ repoImage: RepositoryImage) throws -> URL {
        guard let sourceURL = URL(string: repoImage.downloadUrl),
              let scheme = sourceURL.scheme?.lowercased(),
              Config.allowedURLSchemes.contains(scheme)
        else {
            throw BarkVisorError.badRequest("Invalid download URL for image")
        }
        return sourceURL
    }

    private static func claimCatalogDownload(
        repoImage: RepositoryImage,
        db: DatabasePool,
    ) async throws -> CatalogDownloadClaim {
        let sourceURL = try catalogSourceURL(repoImage)
        return try await ImageService.claimCatalogDownload(
            repoImage: repoImage,
            sourceURL: sourceURL,
            checksum: .catalog(from: repoImage),
            db: db,
        )
    }

    private static func startClaimedDownload(
        claim: CatalogDownloadClaim,
        repoImage: RepositoryImage,
        imageDownloader: any ImageDownloadStarting,
        db: DatabasePool,
    ) async throws -> CatalogDownloadClaim {
        let sourceURL = try catalogSourceURL(repoImage)
        return try await ImageService.startClaimedCatalogDownload(
            claim: claim,
            repoImage: repoImage,
            sourceURL: sourceURL,
            checksum: .catalog(from: repoImage),
            downloader: imageDownloader,
            db: db,
        )
    }

    private static func startCatalogDownload(
        repoImage: RepositoryImage,
        imageDownloader: any ImageDownloadStarting,
        db: DatabasePool,
    ) async throws -> CatalogDownloadClaim {
        let sourceURL = try catalogSourceURL(repoImage)
        return try await ImageService.startOrDetectCatalogDownload(
            repoImage: repoImage,
            sourceURL: sourceURL,
            checksum: .catalog(from: repoImage),
            downloader: imageDownloader,
            db: db,
        )
    }

    private static func existingPending(
        vmName: String, imageId: String, db: DatabasePool,
    ) async throws -> VM? {
        try await db.read { db in
            guard let vm = try VM.filter(Column("name") == vmName).fetchOne(db) else {
                return nil
            }
            let pending = try PendingDeploy
                .filter(PendingDeploy.Columns.vmId == vm.id)
                .filter(PendingDeploy.Columns.imageId == imageId)
                .fetchOne(db)
            return pending == nil ? nil : vm
        }
    }

    private static func insertPlaceholder(
        options: DeployOptions,
        template: VMTemplate,
        repoImage: RepositoryImage,
        imageId: String,
        db: DatabasePool,
    ) async throws -> VM {
        let now = iso8601.string(from: Date())
        let vmID = UUID().uuidString
        let diskID = UUID().uuidString
        let vmType = GuestProfiles.defaultLinuxID(forImageArch: repoImage.arch)
        let cpu = options.cpuCount ?? template.cpuCount
        let mem = options.memoryMB ?? template.memoryMB
        let diskGB = options.diskSizeGB ?? template.diskSizeGB
        let estimatedSize = Int64(diskGB) * 1_024 * 1_024 * 1_024
        let resolvedNetworkId = try await resolveNetwork(
            requestedId: options.networkId, templateMode: template.networkMode,
            vmName: options.vmName, db: db,
        )
        let disksDir = try await db.read { try DiskSettings.resolvedDirectory(from: $0) }
        let diskPath = DiskSettings.fileURL(id: diskID, format: "qcow2", directory: disksDir)
        let payload = try PendingDeploy.encodePayload(
            PendingDeployPayload(options: options, template: template, repoImage: repoImage),
        )
        let disk = Disk(
            id: diskID, name: "\(options.vmName)-disk",
            path: diskPath.path, sizeBytes: estimatedSize,
            format: "qcow2", vmId: vmID, autoCreated: false,
            status: "creating", createdAt: now,
        )
        var vm = VM(
            id: vmID, name: options.vmName, vmType: vmType,
            state: "provisioning",
            cpuCount: cpu, memoryMb: mem,
            bootDiskId: diskID, isoIds: nil,
            networkId: resolvedNetworkId,
            cloudInitPath: nil,
            description: "Deployed from template: \(template.name)",
            bootOrder: nil,
            displayResolution: nil, additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: MACAddress.generateQemu(),
            sharedPaths: nil,
            portForwards: template.portForwards,
            usbDevices: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: now, updatedAt: now,
        )
        vm.syncSpecProjection(bumpGeneration: false)
        let row = vm
        let pending = PendingDeploy(
            vmId: vmID, imageId: imageId, payload: payload, createdAt: now,
        )
        do {
            try await db.write { db in
                try disk.insert(db)
                try row.insert(db)
                try pending.insert(db)
            }
        } catch {
            let existing = try await existingPending(
                vmName: options.vmName, imageId: imageId, db: db,
            )
            if let existing { return existing }
            throw error
        }
        return row
    }

    private static func submitFinishTask(
        vm: VM,
        imageId: String,
        imageDownloader: any ImageDownloadStarting,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
    ) async {
        let vmID = vm.id
        let taskID = deployTaskID(vmID: vmID)
        await backgroundTasks.submit(taskID, kind: .vmProvision) { @Sendable in
            do {
                let pending = try await db.read { db in
                    try PendingDeploy
                        .filter(PendingDeploy.Columns.vmId == vmID)
                        .fetchOne(db)
                }
                guard let pending else { return nil }
                let payload = try pending.decodedPayload()
                _ = try await startCatalogDownload(
                    repoImage: payload.repoImage,
                    imageDownloader: imageDownloader,
                    db: db,
                )
                let localImage = try await waitUntilImageReady(imageId: imageId, db: db)
                _ = try await createViaLifecycle(
                    options: payload.options,
                    template: payload.template,
                    localImage: localImage,
                    vmID: vmID,
                    backgroundTasks: backgroundTasks,
                    db: db,
                )
                try await clearPending(vmID: vmID, db: db)
                return nil
            } catch {
                await failPending(
                    vmID: vmID,
                    message: retryableMessage(error),
                    db: db,
                )
                throw error
            }
        }
    }

    private static func waitUntilImageReady(
        imageId: String, db: DatabasePool,
    ) async throws -> VMImage {
        while true {
            try Task.checkCancellation()
            let image = try await db.read { db in
                try VMImage.fetchOne(db, key: imageId)
            }
            guard let image else {
                throw BarkVisorError.downloadFailed("Image download failed. Retry the template deploy.")
            }
            if image.status == "ready", image.path != nil {
                return image
            }
            if image.status == "error" {
                let detail = image.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if detail.isEmpty {
                    throw BarkVisorError.downloadFailed(
                        "Image download failed. Retry the template deploy.",
                    )
                }
                throw BarkVisorError.downloadFailed(
                    "\(detail). Retry the template deploy.",
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func retryableMessage(_ error: Error) -> String {
        let text = (error as? BarkVisorError)?.sanitizedDescription
            ?? error.localizedDescription
        if text.lowercased().contains("retry") { return text }
        return "\(text). Retry the template deploy."
    }

    private static func failPending(vmID: String, message: String, db: DatabasePool) async {
        let now = iso8601.string(from: Date())
        try? await db.write { db in
            try db.execute(
                sql: "UPDATE vms SET state = 'error', description = ?, updatedAt = ? WHERE id = ?",
                arguments: [message, now, vmID],
            )
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == vmID).deleteAll(db)
        }
    }

    private static func clearPending(vmID: String, db: DatabasePool) async throws {
        try await db.write { db in
            try PendingDeploy.filter(PendingDeploy.Columns.vmId == vmID).deleteAll(db)
        }
    }

    private static func createViaLifecycle(
        options: DeployOptions,
        template: VMTemplate,
        localImage: VMImage,
        vmID: String?,
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
            id: vmID,
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
