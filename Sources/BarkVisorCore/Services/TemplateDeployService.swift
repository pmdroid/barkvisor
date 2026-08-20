import Foundation
import GRDB

public enum DeployResult {
    case downloading(imageId: String)
    /// Disk clone / cloud-init still running (async task).
    case provisioning(taskID: String, vm: VM)
    /// Immediate create (no async provision) — rare for templates (cloud images).
    case created(VM)
}

public struct DeployOptions {
    public let templateId: String
    public let vmName: String
    public let inputs: [String: String]
    public let cpuCount: Int?
    public let memoryMB: Int?
    public let diskSizeGB: Int?
    public let networkId: String?

    public init(
        templateId: String,
        vmName: String,
        inputs: [String: String],
        cpuCount: Int? = nil,
        memoryMB: Int? = nil,
        diskSizeGB: Int? = nil,
        networkId: String? = nil,
    ) {
        self.templateId = templateId
        self.vmName = vmName
        self.inputs = inputs
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.networkId = networkId
    }
}

public enum TemplateDeployService {
    /// Deploy a VM from a template via the shared `VMLifecycleService.createVM` path.
    public static func deploy(
        options: DeployOptions,
        imageDownloader: any ImageDownloadStarting,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
        depot: (any LibraryDepotFetching)? = nil,
    ) async throws -> DeployResult {
        let template = try await fetchTemplate(id: options.templateId, db: db)
        try validateInputs(template: template, inputs: options.inputs)
        let inventory = HostInventoryService.snapshot()
        try enforceCompatibility(template: template, inventory: inventory, options: options)
        let repoImage = try await resolveRepoImage(
            template: template, hostArch: inventory.platform.arch, db: db,
        )
        // PAS-48: reject before downloading a multi-hundred-MB foreign-arch image.
        // createVM also guards via validateCreateVMInputs; this is the early gate.
        try PlatformCapabilities.requireCompatibleGuestArch(repoImage.arch)

        let checksum = ExpectedChecksum.catalog(from: repoImage)
        let localImage = try await db.read { db in
            try ImageService.readyImage(
                sourceUrl: repoImage.downloadUrl, expectedChecksum: checksum, db: db,
            )
        }

        if localImage == nil {
            if let depot {
                if let fetched = await depot.fetchMatching(
                    LibraryDepotFetchRequest(repoImage: repoImage),
                    db: db,
                ) {
                    if fetched.status != "ready" {
                        return .downloading(imageId: fetched.id)
                    }
                    return try await createViaLifecycle(
                        options: options,
                        template: template,
                        localImage: fetched,
                        backgroundTasks: backgroundTasks,
                        db: db,
                    )
                }
            }
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
        guard let sourceURL = URL(string: repoImage.downloadUrl) else {
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
            try CloudInitService.validateUserData(userData)
        }

        let cloudInit = CloudInitConfig(
            sshAuthorizedKeys: sshKeys.isEmpty ? nil : sshKeys,
            userData: userData.isEmpty ? nil : userData,
        )

        let params = CreateVMParams(
            name: options.vmName,
            vmType: vmType,
            cpuCount: cpu,
            memoryMB: mem,
            diskSizeGB: disk,
            cloudImageId: localImage.id,
            cloudInit: cloudInit,
            networkId: resolvedNetworkId,
            portForwards: portForwards,
            description: "Deployed from template: \(template.name)",
            uefi: true,
            tpmEnabled: false,
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
