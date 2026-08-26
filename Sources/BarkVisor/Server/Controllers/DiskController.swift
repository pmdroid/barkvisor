import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct CreateDiskRequest: Content, Validatable {
    let name: String
    var sizeGB: Int?
    var format: String?
    var directory: String?
    var blockDevice: String?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1 ... 128))
    }
}

struct ResizeDiskRequest: Content, Validatable {
    let sizeGB: Int

    static func validations(_ validations: inout Validations) {
        validations.add("sizeGB", as: Int.self, is: .range(1 ... 8_192))
    }
}

struct DiskUsageResponse: Content {
    let virtualSizeBytes: Int64
    let actualSizeBytes: Int64
}

struct DiskResponse: Content {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let format: String
    let vmId: String?
    let autoCreated: Bool
    let status: String
    let createdAt: String
    let attachedTo: [DiskAttachment]

    init(disk: Disk, attachedTo: [DiskAttachment]) {
        id = disk.id
        name = disk.name
        path = disk.path
        sizeBytes = disk.sizeBytes
        format = disk.format
        vmId = disk.vmId
        autoCreated = disk.autoCreated
        status = disk.status
        createdAt = disk.createdAt
        self.attachedTo = attachedTo
    }
}

struct StorageSummaryResponse: Content {
    let totalVirtualBytes: Int64
    let totalActualBytes: Int64
    let diskCount: Int
    let volumeTotalBytes: Int64
    let volumeAvailableBytes: Int64
}

struct TaskAcceptedResponse: Content {
    let taskID: String
}

struct DiskController: RouteCollection {
    let vmState: any VMStateQuerying
    let qmpDiskService: QMPDiskService
    let diskInfoCache: DiskInfoCache

    func boot(routes: any RoutesBuilder) throws {
        let disks = routes.grouped("api", "disks")
        disks.get(use: list)
        disks.get("summary", use: summary)
        disks.post(use: create)
        disks.get(":id", use: get)
        disks.get(":id", "usage", use: usage)
        disks.post(":id", "resize", use: resize)
        disks.delete(":id", use: delete)
    }

    @Sendable
    func list(req: Vapor.Request) async throws -> [DiskResponse] {
        let (limit, offset) = req.pagination()
        return try await req.db.read { db in
            let disks = try Disk.limit(limit, offset: offset).fetchAll(db)
            let attachments = try DiskService.attachmentsByDiskId(vms: VM.fetchAll(db), disks: disks)
            return disks.map { DiskResponse(disk: $0, attachedTo: attachments[$0.id] ?? []) }
        }
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> Disk {
        try CreateDiskRequest.validate(content: req)
        let body = try req.content.decode(CreateDiskRequest.self)
        let disk = try await DiskService.createDisk(
            name: body.name,
            sizeGB: body.sizeGB,
            format: body.format,
            directory: body.directory,
            blockDevice: body.blockDevice,
            db: req.db,
        )
        AuditService.log(
            action: "disk.create", resourceType: "disk", resourceId: disk.id, resourceName: disk.name,
            req: req,
        )
        return disk
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> DiskResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        return try await req.db.read { db in
            guard let disk = try Disk.fetchOne(db, key: id) else {
                throw Abort(.notFound)
            }
            let attachments = try DiskService.attachmentsByDiskId(vms: VM.fetchAll(db), disks: [disk])
            return DiskResponse(disk: disk, attachedTo: attachments[disk.id] ?? [])
        }
    }

    @Sendable
    func usage(req: Vapor.Request) async throws -> DiskUsageResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let disk = try await req.db.read({ db in try Disk.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }

        if let cached = await diskInfoCache.get(id) {
            return DiskUsageResponse(
                virtualSizeBytes: cached.virtualSize, actualSizeBytes: cached.actualSize,
            )
        }

        if DiskSettings.isHostDevicePath(disk.path) {
            return DiskUsageResponse(virtualSizeBytes: disk.sizeBytes, actualSizeBytes: disk.sizeBytes)
        }

        guard FileManager.default.fileExists(atPath: disk.path) else {
            throw Abort(.notFound, reason: "Disk file not found")
        }
        let info = try DiskService.getImageInfo(path: disk.path)
        return DiskUsageResponse(virtualSizeBytes: info.virtualSize, actualSizeBytes: info.actualSize)
    }

    @Sendable
    func summary(req: Vapor.Request) async throws -> StorageSummaryResponse {
        let summary = try await DiskService.storageSummary(diskInfoCache: diskInfoCache, db: req.db)
        return StorageSummaryResponse(
            totalVirtualBytes: summary.totalVirtual,
            totalActualBytes: summary.totalActual,
            diskCount: summary.diskCount,
            volumeTotalBytes: summary.volumeTotal,
            volumeAvailableBytes: summary.volumeFree,
        )
    }

    @Sendable
    func resize(req: Vapor.Request) async throws -> Disk {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try ResizeDiskRequest.validate(content: req)
        let body = try req.content.decode(ResizeDiskRequest.self)
        let disk = try await DiskService.resizeDisk(
            DiskResizeRequest(
                id: id, sizeGB: body.sizeGB, vmState: vmState,
                qmpDiskService: qmpDiskService, diskInfoCache: diskInfoCache,
            ),
            db: req.db,
        )
        AuditService.log(
            action: "disk.resize", resourceType: "disk", resourceId: disk.id, resourceName: disk.name,
            req: req,
        )
        return disk
    }

    @Sendable
    func delete(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let disk = try await DiskService.deleteDisk(id: id, diskInfoCache: diskInfoCache, db: req.db)
        AuditService.log(
            action: "disk.delete", resourceType: "disk", resourceId: id, resourceName: disk.name, req: req,
        )
        return .noContent
    }
}
