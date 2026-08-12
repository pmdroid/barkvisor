import Foundation
import GRDB

// MARK: - Delete VM Helpers

extension VMLifecycleService {
    static func markVMAsDeleting(id: String, db: DatabasePool) async throws {
        let marked = try await db.write { db -> Bool in
            guard let current = try VM.fetchOne(db, key: id),
                  current.state == "stopped" || current.state == "error"
            else {
                return false
            }
            try db.execute(
                sql: "UPDATE vms SET state = 'deleting', updatedAt = ? WHERE id = ?",
                arguments: [iso8601.string(from: Date()), id],
            )
            return true
        }
        guard marked else {
            throw BarkVisorError.conflict("VM state changed concurrently — cannot delete")
        }
    }

    static func deleteVMResources(
        vm: VM,
        keepDisk: Bool,
        db: DatabasePool,
    ) async throws {
        try await deleteOrDetachBootDisk(
            bootDiskId: vm.bootDiskId, vmID: vm.id, keepDisk: keepDisk, db: db,
        )

        let additionalDiskIds = vm.decodedAdditionalDiskIds
        if !additionalDiskIds.isEmpty {
            _ = try await db.write { db in
                for diskId in additionalDiskIds {
                    try db.execute(sql: "UPDATE disks SET vmId = NULL WHERE id = ?", arguments: [diskId])
                }
            }
        }

        if vm.cloudInitPath != nil {
            let ciDir = Config.dataDir.appendingPathComponent("cloud-init/\(vm.id)")
            try? FileManager.default.removeItem(at: ciDir)
        }

        let fwDir = Config.dataDir.appendingPathComponent("efivars/\(vm.id)")
        try? FileManager.default.removeItem(at: fwDir)

        let tpmDir = Config.dataDir.appendingPathComponent("tpm/\(vm.id)")
        try? FileManager.default.removeItem(at: tpmDir)

        if let netId = vm.networkId {
            try await db.write { db in
                guard let network = try Network.fetchOne(db, key: netId), network.autoCreated else {
                    return
                }
                let otherVMs = try VM.filter(Column("networkId") == netId).filter(Column("id") != vm.id)
                    .fetchCount(db)
                if otherVMs == 0 {
                    _ = try Network.deleteOne(db, key: netId)
                }
            }
        }
    }

    private static func deleteOrDetachBootDisk(
        bootDiskId: String,
        vmID: String,
        keepDisk: Bool,
        db: DatabasePool,
    ) async throws {
        if keepDisk {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE disks SET vmId = NULL WHERE id = ?", arguments: [bootDiskId],
                )
            }
            return
        }

        if let disk = try await db.read({ db in try Disk.fetchOne(db, key: bootDiskId) }) {
            let resolvedPath = (disk.path as NSString).resolvingSymlinksInPath
            let canonicalDataDir = (Config.dataDir.path as NSString).resolvingSymlinksInPath
            let dataDirWithSlash =
                canonicalDataDir.hasSuffix("/") ? canonicalDataDir : canonicalDataDir + "/"
            if resolvedPath.hasPrefix(dataDirWithSlash) {
                try? FileManager.default.removeItem(atPath: resolvedPath)
            } else {
                Log.vm.warning(
                    "Refusing to delete disk outside data directory: \(disk.path) -> \(resolvedPath)",
                    vm: vmID,
                )
            }
        }
        _ = try await db.write { db in
            try Disk.filter(Column("id") == bootDiskId).deleteAll(db)
        }
    }
}

// MARK: - Validation

extension VMLifecycleService {
    static func validateCreateVMInputs(
        params: CreateVMParams,
        db: DatabasePool,
    ) async throws {
        try validateVMName(params.name)

        guard let profile = GuestProfiles.profile(for: params.vmType) else {
            let allowed = GuestProfiles.supportedIDs.joined(separator: "', '")
            throw BarkVisorError.badRequest("vmType must be '\(allowed)'")
        }
        // PAS-48: block cross-arch create/deploy (shared by TemplateDeployService).
        try PlatformCapabilities.requireCompatibleGuestArch(profile.arch)
        try validateCPUCount(params.cpuCount)
        guard params.memoryMB >= 128, params.memoryMB <= 1_048_576 else {
            throw BarkVisorError.badRequest("memoryMB must be between 128 and 1048576")
        }

        if let networkId = params.networkId {
            let network = try await db.read { db in try Network.fetchOne(db, key: networkId) }
            guard network != nil else {
                throw BarkVisorError.notFound("Network not found")
            }
        }

        let hasISO = params.isoId != nil
        let hasCloudImage = params.cloudImageId != nil
        let hasExistingDisk = params.existingDiskId != nil

        guard hasISO || hasCloudImage || hasExistingDisk else {
            throw BarkVisorError.badRequest("Must provide isoId, cloudImageId, or existingDiskId")
        }
        guard !(hasISO && hasCloudImage) else {
            throw BarkVisorError.badRequest("Cannot provide both isoId and cloudImageId")
        }

        if let paths = params.sharedPaths {
            for path in paths {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
                else {
                    throw BarkVisorError.badRequest(
                        "Shared path does not exist or is not a directory: \(path)",
                    )
                }
            }
        }

        if let ci = params.cloudInit {
            if let userData = ci.userData,
               !userData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try CloudInitService.validateUserData(userData)
            }
        }

        if let usb = params.usbDevices, !usb.isEmpty {
            try PlatformCapabilities.requireUSBPassthrough()
        }
    }
}
