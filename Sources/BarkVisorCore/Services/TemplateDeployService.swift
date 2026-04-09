import Foundation
import GRDB

public enum DeployResult {
    case downloading(imageId: String)
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
    /// Deploy a VM from a template. Returns either a downloading state or a created VM.
    public static func deploy(
        options: DeployOptions,
        vmManager: VMManager,
        imageDownloader: ImageDownloader,
        db: DatabasePool,
    ) async throws -> DeployResult {
        let template = try await fetchTemplate(id: options.templateId, db: db)
        try validateInputs(template: template, inputs: options.inputs)
        let repoImage = try await resolveRepoImage(template: template, db: db)

        let localImage = try await db.read { db in
            try VMImage.filter(Column("sourceUrl") == repoImage.downloadUrl)
                .filter(Column("status") == "ready")
                .fetchOne(db)
        }

        if localImage == nil {
            return try await startOrDetectDownload(
                repoImage: repoImage, imageDownloader: imageDownloader, db: db,
            )
        }

        guard let localImage else {
            throw BarkVisorError.internalError("Local image unexpectedly nil")
        }
        let vm = try await createVM(
            options: options, template: template,
            localImage: localImage, vmManager: vmManager, db: db,
        )
        return .created(vm)
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
                throw BarkVisorError.badRequest("\(input.label) must be at least \(minLen) characters")
            }
            if let maxLen = input.maxLength, value.count > maxLen {
                throw BarkVisorError.badRequest("\(input.label) must be at most \(maxLen) characters")
            }
        }
    }

    private static func resolveRepoImage(
        template: VMTemplate, db: DatabasePool,
    ) async throws -> RepositoryImage {
        let repoImage: RepositoryImage? = try await db.read { db in
            if let repoId = template.repositoryId {
                if let img =
                    try RepositoryImage
                        .filter(Column("repositoryId") == repoId)
                        .filter(Column("slug") == template.imageSlug)
                        .fetchOne(db) {
                    return img
                }
            }
            return try RepositoryImage.filter(Column("slug") == template.imageSlug).fetchOne(db)
        }
        guard let repoImage else {
            throw BarkVisorError.badRequest(
                "Image \(template.imageSlug) not found in any repository. Please sync your repositories first.",
            )
        }
        return repoImage
    }

    private static func imageFileExtension(
        filename: String, pathExtension: String, imageType: String,
    ) -> String {
        if filename.hasSuffix(".qcow2.xz") || filename.hasSuffix(".img.xz")
            || filename.hasSuffix(".img.gz") || filename.hasSuffix(".qcow2.gz") {
            let parts = filename.split(separator: ".", maxSplits: 1)
            return parts.count > 1 ? String(parts[1]) : (imageType == "iso" ? "iso" : "img")
        }
        if pathExtension.isEmpty {
            return imageType == "iso" ? "iso" : "img"
        }
        return pathExtension
    }

    private static func startOrDetectDownload(
        repoImage: RepositoryImage,
        imageDownloader: ImageDownloader,
        db: DatabasePool,
    ) async throws -> DeployResult {
        guard let sourceURL = URL(string: repoImage.downloadUrl) else {
            throw BarkVisorError.badRequest("Invalid download URL for image")
        }

        let now = iso8601.string(from: Date())
        let imageId = UUID().uuidString
        let ext = imageFileExtension(
            filename: sourceURL.lastPathComponent,
            pathExtension: sourceURL.pathExtension,
            imageType: repoImage.imageType,
        )
        let destination = Config.dataDir.appendingPathComponent("images/\(imageId).\(ext)")

        enum DownloadAction {
            case alreadyDownloading(String)
            case startNew(String)
        }

        let action: DownloadAction = try await db.write { db in
            if let existing =
                try VMImage
                    .filter(Column("sourceUrl") == repoImage.downloadUrl)
                    .filter(Column("status") == "downloading")
                    .fetchOne(db) {
                return .alreadyDownloading(existing.id)
            }

            let image = VMImage(
                id: imageId, name: repoImage.name, imageType: repoImage.imageType,
                arch: repoImage.arch, path: nil, sizeBytes: nil,
                status: "downloading", error: nil, sourceUrl: repoImage.downloadUrl,
                createdAt: now, updatedAt: now,
            )
            try image.insert(db)
            return .startNew(imageId)
        }

        switch action {
        case let .alreadyDownloading(existingId):
            return .downloading(imageId: existingId)
        case let .startNew(newId):
            let checksum: ExpectedChecksum? =
                if let sha256 = repoImage.sha256, !sha256.isEmpty {
                    .sha256(sha256)
                } else if let sha512 = repoImage.sha512, !sha512.isEmpty {
                    .sha512(sha512)
                } else {
                    nil
                }
            await imageDownloader.start(
                imageID: newId, url: sourceURL, destination: destination, expectedChecksum: checksum,
            )
            return .downloading(imageId: newId)
        }
    }

    private static func createVM(
        options: DeployOptions,
        template: VMTemplate,
        localImage: VMImage,
        vmManager: VMManager,
        db: DatabasePool,
    ) async throws -> VM {
        let renderedUserData = try TemplateRenderer.render(
            template: template.userDataTemplate,
            inputs: options.inputs,
        )

        let vmType = localImage.arch == "arm64" ? "linux-arm64" : "linux-\(localImage.arch)"
        let cpu = options.cpuCount ?? template.cpuCount
        let mem = options.memoryMB ?? template.memoryMB
        let disk = options.diskSizeGB ?? template.diskSizeGB

        let now = iso8601.string(from: Date())
        let vmID = UUID().uuidString

        guard let imagePath = localImage.path else {
            throw BarkVisorError.internalError("Image file path missing")
        }
        let diskID = UUID().uuidString
        let diskPath = Config.dataDir.appendingPathComponent("disks/\(diskID).qcow2")
        try DiskService.cloneAndResize(sourcePath: imagePath, destPath: diskPath, sizeGB: disk)
        let diskSize = try DiskService.getVirtualSize(path: diskPath.path)

        let diskRecord = Disk(
            id: diskID, name: "\(options.vmName)-disk",
            path: diskPath.path, sizeBytes: diskSize,
            format: "qcow2", vmId: vmID, autoCreated: true, status: "ready", createdAt: now,
        )

        let cloudInitPath = try generateCloudInit(
            renderedUserData: renderedUserData, inputs: options.inputs,
            vmID: vmID, vmName: options.vmName,
        )

        let resolvedNetworkId = try await resolveNetwork(
            requestedId: options.networkId, templateMode: template.networkMode,
            vmName: options.vmName, db: db,
        )

        let portForwardsJSON: String? = template.portForwards

        let vm = VM(
            id: vmID, name: options.vmName, vmType: vmType, state: "stopped",
            cpuCount: cpu, memoryMb: mem,
            bootDiskId: diskID, isoId: nil, networkId: resolvedNetworkId,
            cloudInitPath: cloudInitPath, vncPort: nil,
            description: "Deployed from template: \(template.name)",
            bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: true, tpmEnabled: vmType == "windows",
            macAddress: MACAddress.generateQemu(),
            sharedPaths: nil,
            portForwards: portForwardsJSON,
            autoCreated: true,
            pendingChanges: false,
            createdAt: now, updatedAt: now,
        )

        try await db.write { db in
            try diskRecord.insert(db)
            try vm.insert(db)
        }

        // Auto-start — clean up on failure
        do {
            try await vmManager.start(vmID: vmID)
        } catch {
            if let ciPath = cloudInitPath {
                try? FileManager.default.removeItem(atPath: ciPath)
            }
            throw error
        }

        return vm
    }

    private static func generateCloudInit(
        renderedUserData: String, inputs: [String: String],
        vmID: String, vmName: String,
    ) throws -> String? {
        guard !renderedUserData.isEmpty else { return nil }

        let sshKeys =
            inputs["ssh_keys"]?
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty } ?? []

        var userData = renderedUserData
        if userData.hasPrefix("#cloud-config\n") {
            userData = String(userData.dropFirst("#cloud-config\n".count))
        }

        if !userData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try CloudInitService.validateUserData(userData)
        }

        let isoURL = try CloudInitService.generateISO(
            vmID: vmID, vmName: vmName,
            sshKeys: sshKeys,
            userData: userData,
        )
        return isoURL.path
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
        } else if templateMode == "bridged" {
            let activeBridge = try await db.read { db in
                try BridgeRecord.filter(Column("status") == "active").fetchOne(db)
            }
            guard let activeBridge else {
                throw BarkVisorError.preconditionFailed(
                    """
                    This template requires bridged networking, but no bridge is active. \
                    Install the BarkVisor Helper and enable a bridge in Settings > Network.
                    """,
                )
            }

            let existing = try await db.read { db in
                try Network.filter(Column("mode") == "bridged" && Column("isDefault") == true).fetchOne(db)
                    ?? Network.filter(
                        Column("mode") == "bridged" && Column("bridge") == activeBridge.interface,
                    ).fetchOne(db)
                    ?? Network.filter(Column("mode") == "bridged").fetchOne(db)
            }
            if let existing {
                return existing.id
            } else {
                let netID = UUID().uuidString
                let network = Network(
                    id: netID, name: "\(vmName) (auto)",
                    mode: "bridged", bridge: activeBridge.interface, macAddress: nil,
                    dnsServer: nil, autoCreated: true, isDefault: false,
                )
                try await db.write { db in
                    try network.insert(db)
                }
                return netID
            }
        } else {
            let defaultNAT = try await db.read { db in
                try Network.filter(Column("mode") == "nat" && Column("isDefault") == true).fetchOne(db)
                    ?? Network.filter(Column("mode") == "nat").fetchOne(db)
            }
            return defaultNAT?.id
        }
    }
}
