import Foundation
import GRDB

public struct DiskImageInfo: Codable, Sendable {
    public let virtualSize: Int64
    public let actualSize: Int64

    public init(virtualSize: Int64, actualSize: Int64) {
        self.virtualSize = virtualSize
        self.actualSize = actualSize
    }
}

public struct StorageSummary: Sendable {
    public let totalVirtual: Int64
    public let totalActual: Int64
    public let diskCount: Int
    public let volumeTotal: Int64
    public let volumeFree: Int64
}

public struct DiskResizeRequest: Sendable {
    public let id: String
    public let sizeGB: Int
    public let vmState: any VMStateQuerying
    public let qmpDiskService: QMPDiskService
    public let diskInfoCache: DiskInfoCache

    public init(
        id: String,
        sizeGB: Int,
        vmState: any VMStateQuerying,
        qmpDiskService: QMPDiskService,
        diskInfoCache: DiskInfoCache,
    ) {
        self.id = id
        self.sizeGB = sizeGB
        self.vmState = vmState
        self.qmpDiskService = qmpDiskService
        self.diskInfoCache = diskInfoCache
    }
}

public enum DiskService {
    public static let supportedFormats: Set<String> = ["qcow2", "raw"]

    /// Fail closed when the data volume cannot hold `neededBytes` plus 512 MiB headroom.
    public static func requireVolumeSpace(neededBytes: Int64, at path: String) throws {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
        let free = (attrs[.systemFreeSize] as? Int64) ?? 0
        let headroom: Int64 = 512 * 1_048_576
        let need = neededBytes + headroom
        if free < need {
            throw BarkVisorError.insufficientDiskSpace(freeBytes: free, neededBytes: need)
        }
    }

    /// qcow2 is sparse; raw needs the full size on disk.
    public static func spaceNeededToCreate(sizeGB: Int, format: String) -> Int64 {
        let gib = Int64(sizeGB) * 1_073_741_824
        if format == "raw" { return gib }
        return min(gib, 1_073_741_824)
    }

    public static func looksLikeNoSpace(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("no space left") || t.contains("enospc")
    }

    /// Create a blank disk image in the given format
    public static func createBlank(path: URL, sizeGB: Int, format: String = "qcow2") throws {
        guard supportedFormats.contains(format) else {
            throw BarkVisorError.diskCreateFailed("Unsupported format: \(format)")
        }
        let dir = path.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try requireVolumeSpace(neededBytes: spaceNeededToCreate(sizeGB: sizeGB, format: format), at: dir)
        let qemuImg = try resolveQEMUImg()
        let result = try PlatformProcess.run(
            executable: qemuImg,
            arguments: ["create", "-f", format, path.path, "\(sizeGB)G"],
            timeout: 300,
        )
        guard result.succeeded else {
            if looksLikeNoSpace(result.stderrString) {
                let free = ((try? FileManager.default.attributesOfFileSystem(forPath: dir))?[.systemFreeSize] as? Int64) ?? 0
                throw BarkVisorError.insufficientDiskSpace(freeBytes: free, neededBytes: spaceNeededToCreate(sizeGB: sizeGB, format: format))
            }
            throw BarkVisorError.diskCreateFailed("qemu-img create failed: \(result.stderrString)")
        }
    }

    /// Clone a cloud image and optionally resize
    public static func cloneAndResize(sourcePath: String, destPath: URL, sizeGB: Int?) throws {
        let dir = destPath.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let needed = spaceNeededToCreate(sizeGB: sizeGB ?? 1, format: "qcow2")
        try requireVolumeSpace(neededBytes: needed, at: dir)
        let qemuImg = try resolveQEMUImg()

        // Convert to qcow2
        let convert = try PlatformProcess.run(
            executable: qemuImg,
            arguments: ["convert", "-f", "qcow2", "-O", "qcow2", sourcePath, destPath.path],
            timeout: 300,
        )
        if !convert.succeeded {
            // Fallback: try without explicit source format
            let convert2 = try PlatformProcess.run(
                executable: qemuImg,
                arguments: ["convert", "-O", "qcow2", sourcePath, destPath.path],
                timeout: 300,
            )
            guard convert2.succeeded else {
                if looksLikeNoSpace(convert.stderrString + convert2.stderrString) {
                    let free = ((try? FileManager.default.attributesOfFileSystem(forPath: dir))?[.systemFreeSize] as? Int64) ?? 0
                    throw BarkVisorError.insufficientDiskSpace(freeBytes: free, neededBytes: needed)
                }
                throw BarkVisorError.diskCreateFailed(
                    "qemu-img convert failed: \(convert2.stderrString)",
                )
            }
        }

        // Grow only if requested size is larger than the cloned image virtual size.
        // Cloud/OVA images (e.g. HAOS) often ship at 32+ GiB; asking for a smaller
        // disk would invoke a shrink, which qemu-img refuses without --shrink and
        // would destroy guest data if forced.
        if let sizeGB, sizeGB > 0 {
            try growIfNeeded(path: destPath.path, sizeGB: sizeGB, qemuImg: qemuImg)
        }

        // HAOS and some cloud images ship with backup GPT not at the end of a
        // larger virtual disk; UEFI then fails with BdsDxe "No bootable option".
        repairGPTBackupHeaderIfPossible(path: destPath.path)
    }

    /// Relocate GPT secondary header to the end of the image when `sgdisk` exists.
    /// Best-effort: never fails provision if tools/nbd are unavailable.
    private static func repairGPTBackupHeaderIfPossible(path: String) {
        let sgdisk = ["/usr/sbin/sgdisk", "/sbin/sgdisk", "/usr/bin/sgdisk"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let sgdisk else { return }

        // Prefer direct sgdisk on the file (works for some setups); fall back quietly.
        // `sgdisk -e` moves the backup GPT to the end of the device.
        let result = try? PlatformProcess.run(
            executable: URL(fileURLWithPath: sgdisk),
            arguments: ["-e", path],
            timeout: 60,
        )
        if result?.succeeded == true {
            return
        }
        // qcow2 usually needs nbd; skip without root rather than failing clone.
        _ = path
    }

    /// Resize a disk image to a new size (grow only — never shrink without an explicit API).
    public static func resize(path: String, sizeGB: Int) throws {
        let qemuImg = try resolveQEMUImg()
        try growIfNeeded(path: path, sizeGB: sizeGB, qemuImg: qemuImg)
    }

    /// Expand `path` to at least `sizeGB` GiB. No-op when already large enough.
    /// Never shrinks: qemu-img requires `--shrink` and would destroy guest data.
    private static func growIfNeeded(path: String, sizeGB: Int, qemuImg: URL) throws {
        let requestedBytes = Int64(sizeGB) * 1_073_741_824
        let current: Int64
        do {
            current = try getVirtualSize(path: path)
        } catch {
            // Cannot determine size — skip resize rather than risk a shrink.
            Log.server.warning(
                "qemu-img info failed for \(path); skipping resize to avoid accidental shrink: \(error)",
            )
            return
        }
        if current <= 0 {
            return
        }
        if current >= requestedBytes {
            return
        }
        let result = try PlatformProcess.run(
            executable: qemuImg,
            arguments: ["resize", path, "\(sizeGB)G"],
            timeout: 300,
        )
        guard result.succeeded else {
            throw BarkVisorError.diskCreateFailed("qemu-img resize failed: \(result.stderrString)")
        }
    }

    /// Coerce qemu-img JSON numbers (Int / Int64 / NSNumber / Double) to Int64.
    /// JSONSerialization on Linux rarely yields `Int64` directly — casting only
    /// `as? Int64` made virtual size look like 0/file-size and triggered false shrinks.
    /// Package-visible for unit tests.
    package static func jsonInt64(_ value: Any?) -> Int64? {
        switch value {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as UInt64: return Int64(clamping: v)
        case let v as NSNumber: return v.int64Value
        case let v as Double: return Int64(v)
        case let v as Float: return Int64(v)
        default: return nil
        }
    }

    /// Get virtual size of a disk image in bytes
    public static func getVirtualSize(path: String) throws -> Int64 {
        let qemuImg = try resolveQEMUImg()
        let result = try PlatformProcess.run(
            executable: qemuImg,
            arguments: ["info", "--output=json", "-U", path],
            timeout: 60,
        )
        if let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
           let virtualSize = jsonInt64(json["virtual-size"]), virtualSize > 0 {
            return virtualSize
        }
        // Fallback to file size (sparse/qcow2 physical size — last resort only)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return attrs[.size] as? Int64 ?? 0
    }

    /// Get disk image info (virtual size and actual on-disk size) via qemu-img info
    public static func getImageInfo(path: String) throws -> DiskImageInfo {
        let qemuImg = try resolveQEMUImg()
        let result = try PlatformProcess.run(
            executable: qemuImg,
            arguments: ["info", "--output=json", "-U", path],
            timeout: 60,
        )
        guard result.succeeded else {
            throw BarkVisorError.diskCreateFailed("qemu-img info failed: \(result.stderrString)")
        }
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else {
            throw BarkVisorError.diskCreateFailed("qemu-img info returned invalid JSON")
        }
        let virtualSize = jsonInt64(json["virtual-size"]) ?? 0
        let actualSize = jsonInt64(json["actual-size"]) ?? 0
        return DiskImageInfo(virtualSize: virtualSize, actualSize: actualSize)
    }

    // MARK: - High-level operations (extracted from DiskController)

    public static func createDisk(
        name: String,
        sizeGB: Int?,
        format: String?,
        directory: String? = nil,
        blockDevice: String? = nil,
        db: DatabasePool,
        fileManager: FileManager = .default,
        allowBlockDevices: Bool? = nil,
        createBlank: ((URL, Int, String) throws -> Void)? = nil,
    ) async throws -> Disk {
        if let blockDevice {
            return try await attachBlockDevice(
                name: name,
                blockDevice: blockDevice,
                directory: directory,
                db: db,
                fileManager: fileManager,
                allowBlockDevices: allowBlockDevices,
            )
        }

        guard let sizeGB, sizeGB >= 1, sizeGB <= 8_192 else {
            throw BarkVisorError.badRequest("sizeGB must be between 1 and 8192")
        }

        let fmt = format ?? "qcow2"
        guard supportedFormats.contains(fmt) else {
            throw BarkVisorError.badRequest(
                "Unsupported format: \(fmt). Supported: \(supportedFormats.sorted().joined(separator: ", "))",
            )
        }

        let dir = try await resolvedCreateDirectory(directory, db: db)
        let id = UUID().uuidString
        let path = DiskSettings.fileURL(id: id, format: fmt, directory: dir)
        if let createBlank {
            try createBlank(path, sizeGB, fmt)
        } else {
            try Self.createBlank(path: path, sizeGB: sizeGB, format: fmt)
        }

        let disk = Disk(
            id: id, name: name, path: path.path,
            sizeBytes: Int64(sizeGB) * 1_024 * 1_024 * 1_024,
            format: fmt, vmId: nil, autoCreated: false,
            status: "ready", createdAt: iso8601.string(from: Date()),
        )
        do {
            try await db.write { db in
                try disk.insert(db)
            }
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw error
        }
        return disk
    }

    private static func attachBlockDevice(
        name: String,
        blockDevice: String,
        directory: String?,
        db: DatabasePool,
        fileManager: FileManager,
        allowBlockDevices: Bool?,
    ) async throws -> Disk {
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BarkVisorError.badRequest("directory cannot be combined with blockDevice")
        }
        let allowed = allowBlockDevices ?? {
            #if os(Linux)
                true
            #else
                false
            #endif
        }()
        guard allowed else {
            throw BarkVisorError.badRequest("Host block devices are only supported on Linux")
        }

        let trimmed = blockDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/dev/") else {
            throw BarkVisorError.badRequest("Block device path must be an absolute /dev path")
        }
        _ = try QEMUBuilder.sanitizeQEMUArg(trimmed, label: "Block device path")
        let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard DiskSettings.isHostDevicePath(path) else {
            throw BarkVisorError.badRequest("Block device path must be an absolute /dev path")
        }
        guard BlockDeviceService.isBlockDevice(path, fileManager: fileManager) else {
            throw BarkVisorError.badRequest("Not a block device: \(path)")
        }
        guard let sizeBytes = BlockDeviceService.sizeBytes(path, fileManager: fileManager), sizeBytes > 0
        else {
            throw BarkVisorError.badRequest("Could not determine size of block device \(path)")
        }

        let existing = try await db.read { db in try Disk.fetchAll(db) }
        if existing.contains(where: { $0.path == path }) {
            throw BarkVisorError.conflict("Block device is already attached as a disk")
        }

        let id = UUID().uuidString
        let disk = Disk(
            id: id, name: name, path: path,
            sizeBytes: sizeBytes,
            format: "raw", vmId: nil, autoCreated: false,
            status: "ready", createdAt: iso8601.string(from: Date()),
        )
        try await db.write { db in
            try disk.insert(db)
        }
        return disk
    }

    private static func resolvedCreateDirectory(_ directory: String?, db: DatabasePool) async throws
        -> URL {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return try await db.read { try DiskSettings.resolvedDirectory(from: $0) }
        }
        guard let prepared = try DiskSettings.validateAndPrepare(trimmed) else {
            return try await db.read { try DiskSettings.resolvedDirectory(from: $0) }
        }
        return prepared
    }

    /// Compute aggregate storage summary across all disks.
    public static func storageSummary(
        diskInfoCache: DiskInfoCache,
        db: DatabasePool,
    ) async throws -> StorageSummary {
        let disks = try await db.read { db in try Disk.fetchAll(db) }
        var totalVirtual: Int64 = 0
        var totalActual: Int64 = 0
        for disk in disks {
            if DiskSettings.isHostDevicePath(disk.path) {
                totalVirtual += disk.sizeBytes
                totalActual += disk.sizeBytes
                continue
            }
            if let cached = await diskInfoCache.get(disk.id) {
                totalVirtual += cached.virtualSize
                totalActual += cached.actualSize
            } else if FileManager.default.fileExists(atPath: disk.path) {
                do {
                    let info = try getImageInfo(path: disk.path)
                    totalVirtual += info.virtualSize
                    totalActual += info.actualSize
                } catch {
                    Log.server.warning("Failed to get image info for disk \(disk.id): \(error)")
                }
            }
        }

        let attrs = try FileManager.default.attributesOfFileSystem(forPath: Config.dataDir.path)
        let volumeTotal = (attrs[.systemSize] as? Int64) ?? 0
        let volumeFree = (attrs[.systemFreeSize] as? Int64) ?? 0

        return StorageSummary(
            totalVirtual: totalVirtual,
            totalActual: totalActual,
            diskCount: disks.count,
            volumeTotal: volumeTotal,
            volumeFree: volumeFree,
        )
    }

    /// Resize a disk (online via QMP if running, offline otherwise). Returns updated disk.
    public static func resizeDisk(
        _ request: DiskResizeRequest,
        db: DatabasePool,
    ) async throws -> Disk {
        guard request.sizeGB >= 1, request.sizeGB <= 8_192 else {
            throw BarkVisorError.badRequest("sizeGB must be between 1 and 8192")
        }

        var disk = try await db.write { db -> Disk in
            guard let disk = try Disk.fetchOne(db, key: request.id) else {
                throw BarkVisorError.notFound()
            }
            if DiskSettings.isHostDevicePath(disk.path) {
                throw BarkVisorError.badRequest("Cannot resize a host block device")
            }
            let newSizeBytes = Int64(request.sizeGB) * 1_024 * 1_024 * 1_024
            guard newSizeBytes > disk.sizeBytes else {
                throw BarkVisorError.badRequest(
                    "New size must be larger than current size (\(disk.sizeBytes / (1_024 * 1_024 * 1_024)) GB)",
                )
            }
            return disk
        }

        let newSizeBytes = Int64(request.sizeGB) * 1_024 * 1_024 * 1_024

        if let vmId = disk.vmId, await request.vmState.isRunning(vmId) {
            try await request.qmpDiskService.resizeDisk(vmID: vmId, disk: disk, sizeBytes: newSizeBytes)
        } else {
            try resize(path: disk.path, sizeGB: request.sizeGB)
        }

        disk.sizeBytes = try getVirtualSize(path: disk.path)

        let updatedDisk = disk
        try await db.write { db in try updatedDisk.update(db) }
        await request.diskInfoCache.invalidate(request.id)
        return disk
    }

    /// Delete a disk: verify not attached, remove file (with path traversal check), delete record.
    public static func deleteDisk(id: String, diskInfoCache: DiskInfoCache, db: DatabasePool)
        async throws -> Disk {
        let disk = try await db.read { db in try Disk.fetchOne(db, key: id) }
        guard let disk else { throw BarkVisorError.notFound() }
        guard disk.vmId == nil else {
            throw BarkVisorError.conflict("Disk is attached to a VM")
        }

        let resolvedPath = (disk.path as NSString).resolvingSymlinksInPath
        let managed = try await db.read { db in
            try LibrarySettings.isManagedStoragePath(disk.path, db: db)
                || DiskSettings.isManagedStoragePath(disk.path, db: db)
        }
        if managed, !DiskSettings.isHostDevicePath(disk.path) {
            do {
                try FileManager.default.removeItem(atPath: resolvedPath)
            } catch let fileError {
                Log.server.warning("Failed to delete disk file at \(resolvedPath): \(fileError)")
                throw BarkVisorError.internalError(
                    "Failed to delete disk file: \(fileError.localizedDescription)",
                )
            }
        } else {
            Log.server.warning(
                "Skipping file deletion for disk outside data/Library/disk directory: \(disk.path) -> \(resolvedPath)",
            )
        }

        let deleted = try await db.write { db in try Disk.deleteOne(db, key: id) }
        guard deleted else { throw BarkVisorError.notFound() }
        await diskInfoCache.invalidate(id)
        return disk
    }

    private static func resolveQEMUImg() throws -> URL {
        do {
            return try BundleResolver.helper("qemu-img")
        } catch {
            throw BarkVisorError.qemuNotFound("qemu-img not found. Install QEMU via: brew install qemu")
        }
    }
}
