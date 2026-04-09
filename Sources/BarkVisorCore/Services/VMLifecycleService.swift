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
        try await validateCreateVMInputs(params: params, db: db)

        let now = iso8601.string(from: Date())
        let vmID = UUID().uuidString

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
    ) async throws -> VM {
        try validateUpdateVMInputs(params: params)

        let encodedFields = encodeUpdateFields(params: params)

        return try await db.write { db -> VM in
            guard var vm = try VM.fetchOne(db, key: id) else {
                throw BarkVisorError.notFound()
            }

            try validateUpdateReferences(params: params, db: db)

            let isRunning = vm.state != "stopped" && vm.state != "error"
            let hardwareChanged = detectHardwareChanges(params: params, encoded: encodedFields, vm: vm)

            applyUpdates(params: params, encoded: encodedFields, to: &vm)

            if isRunning, hardwareChanged { vm.pendingChanges = true }
            vm.updatedAt = iso8601.string(from: Date())

            try vm.update(db)
            return vm
        }
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
        guard cloudImage.arch == "arm64" else {
            throw BarkVisorError.badRequest(
                "Image arch (\(cloudImage.arch)) does not match VM type (\(params.vmType))",
            )
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
            guard iso.arch == "arm64" else {
                throw BarkVisorError.badRequest(
                    "ISO arch (\(iso.arch)) does not match VM type (\(params.vmType))",
                )
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
        VM(
            id: id, name: params.name, vmType: params.vmType,
            state: bootDisk.isCloudImageMode ? "provisioning" : "stopped",
            cpuCount: params.cpuCount, memoryMb: params.memoryMB,
            bootDiskId: bootDisk.diskID, isoId: nil, isoIds: isoIdsJSON,
            networkId: params.networkId,
            cloudInitPath: cloudInitPath, vncPort: nil,
            description: params.description, bootOrder: params.bootOrder,
            displayResolution: params.displayResolution, additionalDiskIds: nil,
            uefi: params.uefi ?? true,
            tpmEnabled: params.tpmEnabled ?? params.vmType.hasPrefix("windows"),
            macAddress: MACAddress.generateQemu(),
            sharedPaths: JSONColumnCoding.encode(params.sharedPaths),
            portForwards: JSONColumnCoding.encode(params.portForwards),
            usbDevices: JSONColumnCoding.encode(params.usbDevices),
            autoCreated: false,
            pendingChanges: false,
            createdAt: now, updatedAt: now,
        )
    }

    fileprivate static func insertVMAndDisk(
        vm: VM,
        disk: Disk?,
        cloudInitPath: String?,
        db: DatabasePool,
    ) async throws {
        do {
            try await db.write { db in
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
    fileprivate struct EncodedUpdateFields {
        let sharedPathsJSON: String?
        let diskIdsJSON: String?
        let portForwardsJSON: String?
        let usbDevicesJSON: String?
    }

    fileprivate static func validateUpdateVMInputs(params: UpdateVMParams) throws {
        if let name = params.name { try validateVMName(name) }
        if let cpu = params.cpuCount {
            guard cpu >= 1, cpu <= 256 else {
                throw BarkVisorError.badRequest("cpuCount must be between 1 and 256")
            }
        }
        if let mem = params.memoryMB {
            guard mem >= 128, mem <= 1_048_576 else {
                throw BarkVisorError.badRequest("memoryMB must be between 128 and 1048576")
            }
        }
    }

    fileprivate static func encodeUpdateFields(params: UpdateVMParams) -> EncodedUpdateFields {
        let sharedPathsJSON: String? =
            if let paths = params.sharedPaths {
                paths.isEmpty ? nil : JSONColumnCoding.encode(paths)
            } else { nil as String? }
        let diskIdsJSON: String? =
            if let diskIds = params.additionalDiskIds {
                JSONColumnCoding.encode(diskIds)
            } else { nil as String? }
        let portForwardsJSON: String? =
            if let pf = params.portForwards {
                pf.isEmpty ? nil : JSONColumnCoding.encode(pf)
            } else { nil as String? }
        let usbDevicesJSON: String? =
            if let usb = params.usbDevices {
                usb.isEmpty ? nil : JSONColumnCoding.encode(usb)
            } else { nil as String? }
        return EncodedUpdateFields(
            sharedPathsJSON: sharedPathsJSON, diskIdsJSON: diskIdsJSON,
            portForwardsJSON: portForwardsJSON, usbDevicesJSON: usbDevicesJSON,
        )
    }

    fileprivate static func validateUpdateReferences(params: UpdateVMParams, db: Database) throws {
        if let net = params.networkId {
            guard try Network.fetchOne(db, key: net) != nil else {
                throw BarkVisorError.notFound("Network not found")
            }
        }
        if let diskIds = params.additionalDiskIds, !diskIds.isEmpty {
            let existingDisks = try Disk.filter(keys: diskIds).fetchAll(db)
            let existingIds = Set(existingDisks.map(\.id))
            let missing = diskIds.filter { !existingIds.contains($0) }
            if !missing.isEmpty {
                throw BarkVisorError.badRequest("Disk(s) not found: \(missing.joined(separator: ", "))")
            }
        }
    }

    fileprivate static func detectHardwareChanges(
        params: UpdateVMParams,
        encoded: EncodedUpdateFields,
        vm: VM,
    ) -> Bool {
        if params.cpuCount != nil, params.cpuCount != vm.cpuCount { return true }
        if params.memoryMB != nil, params.memoryMB != vm.memoryMb { return true }
        if params.networkId != nil, params.networkId != vm.networkId { return true }
        if params.displayResolution != nil, params.displayResolution != vm.displayResolution {
            return true
        }
        if params.bootOrder != nil, params.bootOrder != vm.bootOrder { return true }
        if params.uefi != nil, params.uefi != vm.uefi { return true }
        if params.tpmEnabled != nil, params.tpmEnabled != vm.tpmEnabled { return true }
        if params.sharedPaths != nil { return true }
        if params.additionalDiskIds != nil { return true }
        if params.usbDevices != nil { return true }
        if params.portForwards != nil, encoded.portForwardsJSON != vm.portForwards { return true }
        return false
    }

    fileprivate static func applyUpdates(
        params: UpdateVMParams,
        encoded: EncodedUpdateFields,
        to vm: inout VM,
    ) {
        if let name = params.name { vm.name = name }
        if let cpu = params.cpuCount { vm.cpuCount = cpu }
        if let mem = params.memoryMB { vm.memoryMb = mem }
        if let net = params.networkId { vm.networkId = net }
        if let desc = params.description { vm.description = desc }
        if let boot = params.bootOrder { vm.bootOrder = boot }
        if let res = params.displayResolution { vm.displayResolution = res }
        if let uefi = params.uefi { vm.uefi = uefi }
        if let tpm = params.tpmEnabled { vm.tpmEnabled = tpm }
        if params.sharedPaths != nil { vm.sharedPaths = encoded.sharedPathsJSON }
        if params.additionalDiskIds != nil { vm.additionalDiskIds = encoded.diskIdsJSON }
        if params.usbDevices != nil { vm.usbDevices = encoded.usbDevicesJSON }
        if params.portForwards != nil { vm.portForwards = encoded.portForwardsJSON }
    }
}
