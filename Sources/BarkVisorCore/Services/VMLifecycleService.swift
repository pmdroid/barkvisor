import Foundation
import GRDB

// MARK: - VMLifecycleService

public enum VMLifecycleService {
    // MARK: - Create VM

    public static func createVM(
        params: CreateVMParams,
        db: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
    ) async throws -> CreateVMResult {
        var params = params
        if let imageId = params.cloudImageId {
            let identified = try await db.read { db -> (name: String?, slug: String?) in
                guard let image = try VMImage.fetchOne(db, key: imageId) else {
                    return (nil, nil)
                }
                let slug = try RepositoryImage
                    .filter(Column("name") == image.name)
                    .filter(Column("arch") == image.arch)
                    .fetchOne(db)?.slug
                return (image.name, slug)
            }
            params = try CodingAgentImage.applyingCreateDefaults(
                params: params,
                imageName: identified.name,
                imageSlug: identified.slug,
            )
            params = try OnyxImage.applyingCreateDefaults(
                params: params,
                imageName: identified.name,
                imageSlug: identified.slug,
            )
        }
        try await validateCreateVMInputs(params: params, db: db)

        let now = iso8601.string(from: Date())
        let requestedID = params.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let vmID = requestedID.isEmpty ? UUID().uuidString : requestedID

        let bootDisk = try await resolveBootDisk(
            params: params, vmID: vmID, vmName: params.name, now: now, db: db,
        )

        let cloudInitPath = try resolveCloudInitPath(
            params: params, vmID: vmID, isCloudImageMode: bootDisk.isCloudImageMode,
        )

        let isoIdsJSON = try await resolveISOIds(params: params, db: db)

        let vm = buildVM(
            id: vmID, params: params, now: now,
            bootDisk: bootDisk, cloudInitPath: cloudInitPath,
            isoIdsJSON: isoIdsJSON,
        )

        try await insertVMAndDisk(vm: vm, disk: bootDisk.newDisk, cloudInitPath: cloudInitPath, db: db)

        if bootDisk.isCloudImageMode {
            let taskID = try await submitProvisioningTask(
                vmID: vmID, params: params, diskID: bootDisk.diskID,
                cloudImagePath: bootDisk.cloudImagePath ?? "", db: db, backgroundTasks: backgroundTasks,
            )
            return .provisioning(taskID: taskID, vm: vm)
        }

        return .created(vm)
    }

    // MARK: - Update VM

    public static func updateVM(
        id: String,
        params: UpdateVMParams,
        db: DatabasePool,
        hostGPUDevices: [HostGPUDevice]? = nil,
    ) async throws -> VM {
        let usbDevices = try persistableUSBDevices(params.usbDevices)
        let gpuDevices = try persistableGPUDevices(params.gpuDevices, hostDevices: hostGPUDevices)
        let normalized = UpdateVMParams(
            name: params.name,
            cpuCount: params.cpuCount,
            memoryMB: params.memoryMB,
            networkId: params.networkId,
            portForwards: params.portForwards,
            usbDevices: usbDevices,
            gpuDevices: gpuDevices,
            description: params.description,
            bootOrder: params.bootOrder,
            displayResolution: params.displayResolution,
            additionalDiskIds: params.additionalDiskIds,
            sharedPaths: params.sharedPaths,
            uefi: params.uefi,
            tpmEnabled: params.tpmEnabled,
            workloadClass: params.workloadClass,
            startOnBoot: params.startOnBoot,
        )
        try validateUpdateVMInputs(params: normalized)

        let encodedFields = encodeUpdateFields(params: normalized)

        let vm = try await db.write { db -> VM in
            guard var vm = try VM.fetchOne(db, key: id) else {
                throw BarkVisorError.notFound()
            }

            try validateUpdateReferences(params: normalized, vm: vm, db: db)
            try assertUSBUnclaimed(normalized.usbDevices, excludingVMId: id, db: db)
            try assertGPUUnclaimed(
                normalized.gpuDevices, excludingVMId: id, db: db,
                hostDevices: hostGPUDevices ?? [],
            )

            let isRunning = vm.state != "stopped" && vm.state != "error"
            let hardwareChanged = detectHardwareChanges(
                params: normalized, encoded: encodedFields, vm: vm,
            )
            let specTouched = hardwareChanged
                || params.name != nil
                || params.description != nil

            applyUpdates(params: normalized, encoded: encodedFields, to: &vm)

            if isRunning, hardwareChanged { vm.pendingChanges = true }
            vm.updatedAt = iso8601.string(from: Date())
            vm.syncSpecProjection(bumpGeneration: specTouched)

            try vm.update(db)
            return vm
        }
        if params.gpuDevices != nil {
            try syncCodingAgentCloudInitForGPU(vm: vm)
        }
        return vm
    }

    /// Replace VM columns from a WorkloadSpec (PAS-35). Refreshes stored `specJson`.
    public static func updateVMSpec(
        id: String,
        spec: WorkloadSpec,
        db: DatabasePool,
        hostDevices: [HostUSBDevice]? = nil,
    ) async throws -> VM {
        try WorkloadSpecProjector.validate(spec, existingID: id)
        var normalized = spec
        if !normalized.spec.usb.isEmpty {
            let usbDevices = try persistableUSBDevices(
                normalized.spec.usb.map { USBPassthroughService.passthrough(from: $0) },
                hostDevices: hostDevices,
            ) ?? []
            normalized.spec.usb = usbDevices.map { USBPassthroughService.workload(from: $0) }
        }
        if !normalized.spec.gpu.isEmpty {
            let gpuDevices = try persistableGPUDevices(
                normalized.spec.gpu.map { GPUPassthroughService.passthrough(from: $0) },
            ) ?? []
            normalized.spec.gpu = gpuDevices.map { GPUPassthroughService.workload(from: $0) }
        }
        let spec = normalized
        let (vm, gpuChanged) = try await db.write { db -> (VM, Bool) in
            guard var vm = try VM.fetchOne(db, key: id) else {
                throw BarkVisorError.notFound()
            }
            let isRunning = vm.state != "stopped" && vm.state != "error"
            let before = vm
            try WorkloadSpecProjector.apply(spec, to: &vm)
            try validateAppliedVMSpec(spec: spec, vm: vm, db: db)
            try assertUSBUnclaimed(vm.decodedUSBDevices, excludingVMId: id, db: db)
            try assertGPUUnclaimed(vm.decodedGPUDevices, excludingVMId: id, db: db)
            if isRunning, detectHardwareChanges(before: before, after: vm) {
                vm.pendingChanges = true
            }
            vm.updatedAt = iso8601.string(from: Date())
            vm.syncSpecProjection(bumpGeneration: true)
            try vm.update(db)
            return (vm, before.gpuDevices != vm.gpuDevices)
        }
        if gpuChanged {
            try syncCodingAgentCloudInitForGPU(vm: vm)
        }
        return vm
    }

    // MARK: - Delete VM

    public static func deleteVM(
        id: String,
        keepDisk: Bool,
        vmManager: VMManager,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
    ) async throws -> (taskID: String, vmName: String) {
        let vm = try await db.read { db in try VM.fetchOne(db, key: id) }
        guard let vm else { throw BarkVisorError.notFound() }

        guard vm.state == "stopped" || vm.state == "error" else {
            throw BarkVisorError.conflict("VM must be stopped before deleting")
        }

        guard await !vmManager.isActiveOrStarting(id) else {
            throw BarkVisorError.conflict("VM is currently starting or running")
        }

        try await markVMAsDeleting(id: id, db: db)

        let taskID = "vm-delete:\(id)"
        await backgroundTasks.submit(taskID, kind: .vmDelete) { @Sendable in
            do {
                try await deleteVMResources(vm: vm, keepDisk: keepDisk, db: db)
                _ = try await db.write { db in try VM.deleteOne(db, key: id) }
                return nil
            } catch {
                await handleDeleteFailure(vmID: id, db: db, error: error)
                throw error
            }
        }

        return (taskID: taskID, vmName: vm.name)
    }
}

// MARK: - Create VM Helpers

extension VMLifecycleService {
    fileprivate struct BootDiskResult {
        let diskID: String
        let newDisk: Disk?
        let isCloudImageMode: Bool
        let cloudImagePath: String?
    }

    fileprivate static func resolveBootDisk(
        params: CreateVMParams,
        vmID: String,
        vmName: String,
        now: String,
        db: DatabasePool,
    ) async throws -> BootDiskResult {
        if let existingId = params.existingDiskId {
            let diskID = try await db.write { db in
                if try VM.fetchOne(db, key: vmID) != nil {
                    throw BarkVisorError.conflict("Workload \(vmID) already exists")
                }
                guard let disk = try Disk.fetchOne(db, key: existingId) else {
                    throw BarkVisorError.badRequest("Disk not found")
                }
                guard disk.vmId == nil else {
                    throw BarkVisorError.badRequest("Disk is already attached to another VM")
                }
                try db.execute(
                    sql: "UPDATE disks SET vmId = ? WHERE id = ?", arguments: [vmID, existingId],
                )
                return existingId
            }
            return BootDiskResult(
                diskID: diskID, newDisk: nil, isCloudImageMode: false, cloudImagePath: nil,
            )
        }

        if params.cloudImageId != nil {
            return try await resolveCloudImageDisk(
                params: params, vmID: vmID, vmName: vmName, now: now, db: db,
            )
        }

        return try await resolveISOModeDisk(
            params: params, vmID: vmID, vmName: vmName, now: now, db: db,
        )
    }

    fileprivate static func resolveCloudImageDisk(
        params: CreateVMParams,
        vmID: String,
        vmName: String,
        now: String,
        db: DatabasePool,
    ) async throws -> BootDiskResult {
        guard let cloudImageId = params.cloudImageId else {
            throw BarkVisorError.internalError("cloudImageId unexpectedly nil")
        }
        let cloudImage = try await db.read { db in
            try VMImage.fetchOne(db, key: cloudImageId)
        }
        guard let cloudImage, cloudImage.imageType == "cloud-image", cloudImage.status == "ready",
              let imagePath = cloudImage.path
        else {
            throw BarkVisorError.badRequest("Cloud image not found or not ready")
        }
        if let profile = GuestProfiles.profile(for: params.vmType) {
            let imageArchNorm = PlatformCapabilities.normalizedArch(cloudImage.arch)
            guard imageArchNorm == profile.arch else {
                throw BarkVisorError.badRequest(
                    "Image arch (\(cloudImage.arch)) does not match VM type (\(params.vmType))",
                )
            }
        }

        let id = UUID().uuidString
        let diskPath = Config.dataDir.appendingPathComponent("disks/\(id).qcow2")
        let estimatedSize = Int64(params.diskSizeGB ?? 20) * 1_024 * 1_024 * 1_024

        let disk = Disk(
            id: id, name: "\(vmName)-disk",
            path: diskPath.path, sizeBytes: estimatedSize,
            format: "qcow2", vmId: vmID, autoCreated: false,
            status: "creating", createdAt: now,
        )
        return BootDiskResult(
            diskID: id, newDisk: disk, isCloudImageMode: true, cloudImagePath: imagePath,
        )
    }

    fileprivate static func resolveISOModeDisk(
        params: CreateVMParams,
        vmID: String,
        vmName: String,
        now: String,
        db: DatabasePool,
    ) async throws -> BootDiskResult {
        guard let diskSizeGB = params.diskSizeGB, diskSizeGB >= 1 else {
            throw BarkVisorError.badRequest("diskSizeGB required for ISO mode and must be >= 1")
        }

        if let isoId = params.isoId {
            let iso = try await db.read { db in
                try VMImage.fetchOne(db, key: isoId)
            }
            guard let iso, iso.imageType == "iso", iso.status == "ready" else {
                throw BarkVisorError.badRequest("ISO image not found or not ready")
            }
            if let profile = GuestProfiles.profile(for: params.vmType) {
                let imageArchNorm = PlatformCapabilities.normalizedArch(iso.arch)
                guard imageArchNorm == profile.arch else {
                    throw BarkVisorError.badRequest(
                        "ISO arch (\(iso.arch)) does not match VM type (\(params.vmType))",
                    )
                }
            }
        }

        let id = UUID().uuidString
        let diskPath = Config.dataDir.appendingPathComponent("disks/\(id).qcow2")
        try DiskService.createBlank(path: diskPath, sizeGB: diskSizeGB)
        let diskSize = Int64(diskSizeGB) * 1_024 * 1_024 * 1_024

        let disk = Disk(
            id: id, name: "\(vmName)-disk",
            path: diskPath.path, sizeBytes: diskSize,
            format: "qcow2", vmId: vmID, autoCreated: false,
            status: "ready", createdAt: now,
        )
        return BootDiskResult(diskID: id, newDisk: disk, isCloudImageMode: false, cloudImagePath: nil)
    }

    fileprivate static func resolveCloudInitPath(
        params: CreateVMParams,
        vmID: String,
        isCloudImageMode: Bool,
    ) throws -> String? {
        guard !isCloudImageMode else { return nil }
        let ciKeys = params.cloudInit?.sshAuthorizedKeys?.filter { !$0.isEmpty } ?? []
        let ciUserData = params.cloudInit?.userData?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ciKeys.isEmpty || !(ciUserData ?? "").isEmpty else { return nil }
        let isoURL = try CloudInitService.generateISO(
            vmID: vmID, vmName: params.name,
            sshKeys: ciKeys,
            userData: ciUserData,
            instanceID: CodingAgentImage.cloudInitInstanceID(
                vmID: vmID, userData: ciUserData, gpuDevices: params.gpuDevices,
            ),
        )
        return isoURL.path
    }

    fileprivate static func resolveISOIds(
        params: CreateVMParams,
        db: DatabasePool,
    ) async throws -> String? {
        var isoIdList: [String] = []
        if let isoId = params.isoId { isoIdList.append(isoId) }
        if params.vmType.hasPrefix("windows") {
            let virtioWinUrl =
                "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
            let virtioImage = try await db.read { db in
                try VMImage
                    .filter(Column("sourceUrl") == virtioWinUrl)
                    .filter(Column("status") == "ready")
                    .fetchOne(db)
            }
            if let virtioImage, !isoIdList.contains(virtioImage.id) {
                isoIdList.append(virtioImage.id)
            }
        }
        return isoIdList.isEmpty ? nil : JSONColumnCoding.encode(isoIdList)
    }

    // swiftlint:disable:next function_parameter_count
    fileprivate static func buildVM(
        id: String,
        params: CreateVMParams,
        now: String,
        bootDisk: BootDiskResult,
        cloudInitPath: String?,
        isoIdsJSON: String?,
    ) -> VM {
        var vm = VM(
            id: id, name: params.name, vmType: params.vmType,
            state: bootDisk.isCloudImageMode ? "provisioning" : "stopped",
            cpuCount: params.cpuCount, memoryMb: params.memoryMB,
            bootDiskId: bootDisk.diskID, isoIds: isoIdsJSON,
            networkId: params.networkId,
            cloudInitPath: cloudInitPath,
            description: params.description, bootOrder: params.bootOrder,
            displayResolution: params.displayResolution, additionalDiskIds: nil,
            uefi: params.uefi ?? true,
            tpmEnabled: params.tpmEnabled ?? params.vmType.hasPrefix("windows"),
            macAddress: MACAddress.generateQemu(),
            sharedPaths: JSONColumnCoding.encode(params.sharedPaths),
            portForwards: JSONColumnCoding.encode(params.portForwards),
            usbDevices: JSONColumnCoding.encode(
                (try? persistableUSBDevices(params.usbDevices)) ?? params.usbDevices,
            ),
            gpuDevices: JSONColumnCoding.encode(
                (try? persistableGPUDevices(params.gpuDevices)) ?? params.gpuDevices,
            ),
            autoCreated: false,
            pendingChanges: false,
            workloadClass: (try? WorkloadClass.parse(params.workloadClass).rawValue)
                ?? WorkloadClass.house.rawValue,
            createdAt: now, updatedAt: now,
        )
        vm.setOverrides(params.overrides)
        vm.setHealth(params.health)
        if (try? WorkloadClass.parse(params.workloadClass)) == .agent {
            let grant = CodingAgentSession.usesHomeOllamaGrant(userData: params.cloudInit?.userData)
                ? CodingAgentSession.grant
                : "byo"
            vm.setSession(
                CodingAgentLifecycle.seed(
                    grant: grant,
                    cloudImageId: params.cloudImageId,
                    diskSizeGB: params.diskSizeGB,
                ),
            )
        }
        vm.syncSpecProjection(bumpGeneration: false)
        return vm
    }

    fileprivate static func insertVMAndDisk(
        vm: VM,
        disk: Disk?,
        cloudInitPath: String?,
        db: DatabasePool,
    ) async throws {
        do {
            try await db.write { db in
                try assertUSBUnclaimed(vm.decodedUSBDevices, excludingVMId: vm.id, db: db)
                try assertGPUUnclaimed(vm.decodedGPUDevices, excludingVMId: vm.id, db: db)
                if let d = disk {
                    try d.insert(db)
                }
                try vm.insert(db)
            }
        } catch {
            Log.vm.error("VM creation failed during DB insert: \(error)")
            if let disk {
                try? FileManager.default.removeItem(atPath: disk.path)
            }
            if let ciPath = cloudInitPath {
                try? FileManager.default.removeItem(atPath: ciPath)
            }
            throw error
        }
    }

    // swiftlint:disable:next function_parameter_count
    fileprivate static func submitProvisioningTask(
        vmID: String,
        params: CreateVMParams,
        diskID: String,
        cloudImagePath: String,
        db: DatabasePool,
        backgroundTasks: BackgroundTaskManager,
    ) async throws -> String {
        let taskID = "disk-clone:\(vmID)"
        let capturedDiskSizeGB = params.diskSizeGB
        let diskPath = Config.dataDir.appendingPathComponent("disks/\(diskID).qcow2")
        let sshKeys = params.cloudInit?.sshAuthorizedKeys?.filter { !$0.isEmpty } ?? []
        let userData = params.cloudInit?.userData?.trimmingCharacters(in: .whitespacesAndNewlines)
        let vmName = params.name
        let gpuDevices = params.gpuDevices
        let hasCloudInit = !sshKeys.isEmpty || !(userData ?? "").isEmpty

        await backgroundTasks.submit(taskID, kind: .vmProvision) { @Sendable in
            do {
                try DiskService.cloneAndResize(
                    sourcePath: cloudImagePath, destPath: diskPath, sizeGB: capturedDiskSizeGB,
                )
                let diskSize = try DiskService.getVirtualSize(path: diskPath.path)

                let ciPath: String? =
                    if hasCloudInit {
                        try CloudInitService.generateISO(
                            vmID: vmID, vmName: vmName,
                            sshKeys: sshKeys, userData: userData,
                            instanceID: CodingAgentImage.cloudInitInstanceID(
                                vmID: vmID, userData: userData, gpuDevices: gpuDevices,
                            ),
                        ).path
                    } else {
                        nil
                    }

                let now = iso8601.string(from: Date())
                try await db.write { db in
                    try db.execute(
                        sql: "UPDATE disks SET status = 'ready', sizeBytes = ? WHERE id = ?",
                        arguments: [diskSize, diskID],
                    )
                    if let ciPath {
                        try db.execute(
                            sql:
                            "UPDATE vms SET state = 'stopped', cloudInitPath = ?, updatedAt = ? WHERE id = ?",
                            arguments: [ciPath, now, vmID],
                        )
                    } else {
                        try db.execute(
                            sql: "UPDATE vms SET state = 'stopped', updatedAt = ? WHERE id = ?",
                            arguments: [now, vmID],
                        )
                    }
                }
            } catch {
                await handleProvisionFailure(
                    vmID: vmID,
                    diskID: diskID,
                    diskPath: diskPath.path,
                    db: db,
                    error: error,
                )
                throw error
            }
            return nil
        }

        return taskID
    }
}

// MARK: - Update VM Helpers

extension VMLifecycleService {
    /// Network existence, spec/record mode, and port occupancy after a spec is projected.
    /// Shared by `updateVMSpec` and PAS-80 dry-run apply.
    static func validateAppliedVMSpec(spec: WorkloadSpec, vm: VM, db: Database) throws {
        let appliedNetwork: Network? =
            if let netId = vm.networkId {
                try Network.fetchOne(db, key: netId)
            } else {
                nil
            }
        if vm.networkId != nil, appliedNetwork == nil {
            throw BarkVisorError.notFound("Network not found")
        }
        if let specNet = spec.spec.networks.first {
            try NetworkCapability.requireSpecNetwork(specNet, record: appliedNetwork)
        } else {
            try NetworkCapability.requirePortForwardsAllowed(
                count: vm.decodedPortForwards.count,
                network: appliedNetwork,
            )
        }
        try PortRegistry.assertAvailable(
            vm.decodedPortForwards, excludingVM: vm.id, db: db,
        )
        try assertUSBUnclaimed(vm.decodedUSBDevices, excludingVMId: vm.id, db: db)
        try assertGPUUnclaimed(vm.decodedGPUDevices, excludingVMId: vm.id, db: db)
        try AgentWorkloadPolicy.validate(spec: spec, network: appliedNetwork)
    }

    fileprivate static func validateUpdateVMInputs(params: UpdateVMParams) throws {
        if let name = params.name { try validateVMName(name) }
        if let cpu = params.cpuCount {
            try validateCPUCount(cpu)
        }
        if let mem = params.memoryMB {
            guard mem >= 128, mem <= 1_048_576 else {
                throw BarkVisorError.badRequest("memoryMB must be between 128 and 1048576")
            }
        }
        if let usb = params.usbDevices, !usb.isEmpty {
            try PlatformCapabilities.requireUSBPassthrough()
        }
        if let gpu = params.gpuDevices, !gpu.isEmpty {
            try PlatformCapabilities.requireGPUPassthrough()
        }
    }

    /// vCPUs must be at least 1 and at most the host online logical CPU count.
    static func validateCPUCount(_ cpuCount: Int) throws {
        let hostCPUs = PlatformHost.cpuCount
        guard cpuCount >= 1, cpuCount <= hostCPUs else {
            throw BarkVisorError.badRequest(
                "cpuCount must be between 1 and \(hostCPUs) (host has \(hostCPUs) logical CPU\(hostCPUs == 1 ? "" : "s"))",
            )
        }
    }

    fileprivate static func validateUpdateReferences(
        params: UpdateVMParams,
        vm: VM,
        db: Database,
    ) throws {
        let networkId = params.networkId ?? vm.networkId
        let network: Network? =
            if let networkId {
                try Network.fetchOne(db, key: networkId)
            } else {
                nil
            }
        if networkId != nil, network == nil {
            throw BarkVisorError.notFound("Network not found")
        }
        let forwardCount =
            params.portForwards?.count ?? vm.decodedPortForwards.count
        try NetworkCapability.requirePortForwardsAllowed(count: forwardCount, network: network)
        let rules = params.portForwards ?? vm.decodedPortForwards
        try PortRegistry.assertAvailable(rules, excludingVM: vm.id, db: db)
        if let diskIds = params.additionalDiskIds, !diskIds.isEmpty {
            let existingDisks = try Disk.filter(keys: diskIds).fetchAll(db)
            let existingIds = Set(existingDisks.map(\.id))
            let missing = diskIds.filter { !existingIds.contains($0) }
            if !missing.isEmpty {
                throw BarkVisorError.badRequest("Disk(s) not found: \(missing.joined(separator: ", "))")
            }
        }
        let klass = try WorkloadClass.parse(params.workloadClass ?? vm.workloadClass)
        try AgentWorkloadPolicy.validate(
            workloadClass: klass,
            usbCount: (params.usbDevices ?? vm.decodedUSBDevices).count,
            sharedPathCount: (params.sharedPaths ?? vm.decodedSharedPaths).count,
            portForwardCount: (params.portForwards ?? vm.decodedPortForwards).count,
            networkMode: NetworkCapability.effectiveMode(of: network),
        )
    }
}
