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

    /// Create a blank disk image in the given format
    public static func createBlank(path: URL, sizeGB: Int, format: String = "qcow2") throws {
        guard supportedFormats.contains(format) else {
            throw BarkVisorError.diskCreateFailed("Unsupported format: \(format)")
        }
        let qemuImg = try resolveQEMUImg()
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["create", "-f", format, path.path, "\(sizeGB)G"]
        let pipe = Pipe()
        process.standardError = pipe
        try runWithTimeout(process)
        guard process.terminationStatus == 0 else {
            let stderr =
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BarkVisorError.diskCreateFailed("qemu-img create failed: \(stderr)")
        }
    }

    /// Clone a cloud image and optionally resize
    public static func cloneAndResize(sourcePath: String, destPath: URL, sizeGB: Int?) throws {
        let qemuImg = try resolveQEMUImg()

        // Convert to qcow2
        let convert = Process()
        convert.executableURL = qemuImg
        convert.arguments = ["convert", "-f", "qcow2", "-O", "qcow2", sourcePath, destPath.path]
        let pipe1 = Pipe()
        convert.standardError = pipe1
        try runWithTimeout(convert)
        if convert.terminationStatus != 0 {
            // Fallback: try without explicit source format
            let convert2 = Process()
            convert2.executableURL = qemuImg
            convert2.arguments = ["convert", "-O", "qcow2", sourcePath, destPath.path]
            let pipe1b = Pipe()
            convert2.standardError = pipe1b
            try runWithTimeout(convert2)
            guard convert2.terminationStatus == 0 else {
                let stderr =
                    String(data: pipe1b.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw BarkVisorError.diskCreateFailed("qemu-img convert failed: \(stderr)")
            }
        }

        // Resize if requested
        if let sizeGB, sizeGB > 0 {
            let resize = Process()
            resize.executableURL = qemuImg
            resize.arguments = ["resize", destPath.path, "\(sizeGB)G"]
            let pipe2 = Pipe()
            resize.standardError = pipe2
            try runWithTimeout(resize)
            guard resize.terminationStatus == 0 else {
                let stderr =
                    String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw BarkVisorError.diskCreateFailed("qemu-img resize failed: \(stderr)")
            }
        }
    }

    /// Resize a disk image to a new size
    public static func resize(path: String, sizeGB: Int) throws {
        let qemuImg = try resolveQEMUImg()
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["resize", path, "\(sizeGB)G"]
        let pipe = Pipe()
        process.standardError = pipe
        try runWithTimeout(process)
        guard process.terminationStatus == 0 else {
            let stderr =
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BarkVisorError.diskCreateFailed("qemu-img resize failed: \(stderr)")
        }
    }

    /// Get virtual size of a disk image in bytes
    public static func getVirtualSize(path: String) throws -> Int64 {
        let qemuImg = try resolveQEMUImg()
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["info", "--output=json", "-U", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try runWithTimeout(process)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let virtualSize = json["virtual-size"] as? Int64 {
            return virtualSize
        }
        // Fallback to file size
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return attrs[.size] as? Int64 ?? 0
    }

    /// Get disk image info (virtual size and actual on-disk size) via qemu-img info
    public static func getImageInfo(path: String) throws -> DiskImageInfo {
        let qemuImg = try resolveQEMUImg()
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["info", "--output=json", "-U", path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try runWithTimeout(process)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr =
                String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BarkVisorError.diskCreateFailed("qemu-img info failed: \(stderr)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BarkVisorError.diskCreateFailed("qemu-img info returned invalid JSON")
        }
        let virtualSize = (json["virtual-size"] as? Int64) ?? 0
        let actualSize = (json["actual-size"] as? Int64) ?? 0
        return DiskImageInfo(virtualSize: virtualSize, actualSize: actualSize)
    }

    /// Run a `Process` with a timeout to avoid blocking the thread indefinitely.
    private static func runWithTimeout(_ process: Process, timeout: TimeInterval = 300) throws {
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw BarkVisorError.timeout("Process timed out after \(Int(timeout))s")
        }
    }

    // MARK: - High-level operations (extracted from DiskController)

    /// Create a new disk image and persist the record.
    public static func createDisk(name: String, sizeGB: Int, format: String?, db: DatabasePool)
        async throws -> Disk {
        guard sizeGB >= 1, sizeGB <= 8_192 else {
            throw BarkVisorError.badRequest("sizeGB must be between 1 and 8192")
        }

        let fmt = format ?? "qcow2"
        guard supportedFormats.contains(fmt) else {
            throw BarkVisorError.badRequest(
                "Unsupported format: \(fmt). Supported: \(supportedFormats.sorted().joined(separator: ", "))",
            )
        }

        let id = UUID().uuidString
        let ext = fmt == "raw" ? "img" : "qcow2"
        let path = Config.dataDir.appendingPathComponent("disks/\(id).\(ext)")
        try createBlank(path: path, sizeGB: sizeGB, format: fmt)

        let disk = Disk(
            id: id, name: name, path: path.path,
            sizeBytes: Int64(sizeGB) * 1_024 * 1_024 * 1_024,
            format: fmt, vmId: nil, autoCreated: false,
            status: "ready", createdAt: iso8601.string(from: Date()),
        )
        try await db.write { db in
            try disk.insert(db)
        }
        return disk
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

        // Resolve symlinks and canonicalize both paths before comparison
        let resolvedPath = (disk.path as NSString).resolvingSymlinksInPath
        let canonicalDataDir = (Config.dataDir.path as NSString).resolvingSymlinksInPath
        let dataDirWithSlash =
            canonicalDataDir.hasSuffix("/") ? canonicalDataDir : canonicalDataDir + "/"
        if resolvedPath.hasPrefix(dataDirWithSlash) {
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
                "Skipping file deletion for disk outside data directory: \(disk.path) -> \(resolvedPath)",
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
