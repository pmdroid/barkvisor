import BarkVisorCore
import Foundation
import GRDB
import Vapor

// MARK: - DTOs

struct VMResponse: Content {
    let id: String
    let name: String
    let vmType: String
    let state: String
    let cpuCount: Int
    let memoryMB: Int
    let bootDiskId: String
    let isoId: String? // Backwards compat: first element of isoIds
    let isoIds: [String]?
    let networkId: String?
    let cloudInitPath: String?
    let description: String?
    let bootOrder: String?
    let displayResolution: String?
    let additionalDiskIds: [String]?
    let uefi: Bool
    let tpmEnabled: Bool
    let macAddress: String?
    let sharedPaths: [String]?
    let portForwards: [PortForwardRule]?
    let usbDevices: [USBPassthroughDevice]?
    let pendingChanges: Bool
    let createdAt: String
    let updatedAt: String

    init(from vm: VM) {
        self.id = vm.id
        self.name = vm.name
        self.vmType = vm.vmType
        self.state = vm.state
        self.cpuCount = vm.cpuCount
        self.memoryMB = vm.memoryMb
        self.bootDiskId = vm.bootDiskId
        let decodedIsoIds =
            JSONColumnCoding.decodeArray(String.self, from: vm.isoIds)
                ?? {
                    if let legacyId = vm.isoId { return [legacyId] }
                    return []
                }()
        self.isoIds = decodedIsoIds.isEmpty ? nil : decodedIsoIds
        self.isoId = decodedIsoIds.first
        self.networkId = vm.networkId
        self.cloudInitPath = vm.cloudInitPath
        self.description = vm.description
        self.bootOrder = vm.bootOrder
        self.displayResolution = vm.displayResolution
        self.uefi = vm.uefi
        self.tpmEnabled = vm.tpmEnabled
        self.macAddress = vm.macAddress
        self.pendingChanges = vm.pendingChanges
        self.createdAt = vm.createdAt
        self.updatedAt = vm.updatedAt
        self.additionalDiskIds = JSONColumnCoding.decodeArray(String.self, from: vm.additionalDiskIds)
        self.sharedPaths = JSONColumnCoding.decodeArray(String.self, from: vm.sharedPaths)
        self.portForwards = JSONColumnCoding.decodeArray(PortForwardRule.self, from: vm.portForwards)
        self.usbDevices = JSONColumnCoding.decodeArray(USBPassthroughDevice.self, from: vm.usbDevices)
    }
}

struct CreateVMRequest: Content, Validatable {
    let name: String
    let vmType: String
    let cpuCount: Int
    let memoryMB: Int
    let diskSizeGB: Int?
    let isoId: String?
    let cloudImageId: String?
    let cloudInit: CloudInitConfig?
    let networkId: String?
    let existingDiskId: String?
    let sharedPaths: [String]?
    let portForwards: [PortForwardRule]?
    let usbDevices: [USBPassthroughDevice]?
    let description: String?
    let bootOrder: String?
    let displayResolution: String?
    let uefi: Bool?
    let tpmEnabled: Bool?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1 ... 128))
        validations.add("vmType", as: String.self, is: .in("linux-arm64", "windows-arm64"))
        validations.add("cpuCount", as: Int.self, is: .range(1 ... 256))
        validations.add("memoryMB", as: Int.self, is: .range(128 ... 1_048_576))
    }
}

/// CloudInitConfig moved to BarkVisorCore
extension CloudInitConfig: Content {}

struct UpdateVMRequest: Content, Validatable {
    let name: String?
    let cpuCount: Int?
    let memoryMB: Int?
    let networkId: String?
    let portForwards: [PortForwardRule]?
    let usbDevices: [USBPassthroughDevice]?
    let description: String?
    let bootOrder: String?
    let displayResolution: String?
    let additionalDiskIds: [String]?
    let sharedPaths: [String]?
    let uefi: Bool?
    let tpmEnabled: Bool?

    static func validations(_ validations: inout Validations) {
        validations.add("cpuCount", as: Int?.self, is: .nil || .range(1 ... 256), required: false)
        validations.add("memoryMB", as: Int?.self, is: .nil || .range(128 ... 1_048_576), required: false)
    }
}

struct StopVMRequest: Content {
    let force: Bool?
    let method: String?
}

struct VMTaskAcceptedResponse: Content {
    let taskID: String
    let vm: VMResponse
}

struct GuestInfoResponse: Content {
    let available: Bool
    let ipAddresses: [String]
    let macAddress: String?
    let ipSource: String
    let hostname: String?
    let osName: String?
    let osVersion: String?
    let osId: String?
    let kernelVersion: String?
    let kernelRelease: String?
    let machine: String?
    let timezone: String?
    let timezoneOffset: Int?
    let users: [GuestUserDTO]?
    let filesystems: [GuestFilesystemDTO]?

    init(from r: GuestInfoResult) {
        self.available = r.available
        self.ipAddresses = r.ipAddresses
        self.macAddress = r.macAddress
        self.ipSource = r.ipSource
        self.hostname = r.hostname
        self.osName = r.osName
        self.osVersion = r.osVersion
        self.osId = r.osId
        self.kernelVersion = r.kernelVersion
        self.kernelRelease = r.kernelRelease
        self.machine = r.machine
        self.timezone = r.timezone
        self.timezoneOffset = r.timezoneOffset
        self.users = r.users
        self.filesystems = r.filesystems
    }
}

// MARK: - Controller

struct VMController: RouteCollection {
    let vmManager: VMManager
    let qmpDiskService: QMPDiskService
    let metricsCollector: MetricsCollector
    let stateStreamService: VMStateStreamService
    let backgroundTasks: BackgroundTaskManager

    func boot(routes: any RoutesBuilder) throws {
        let vms = routes.grouped("api", "vms")
        vms.get(use: list)
        vms.post(use: create)
        vms.get(":id", use: get)
        vms.patch(":id", use: update)
        vms.delete(":id", use: delete)
        vms.post(":id", "start", use: start)
        vms.post(":id", "stop", use: stop)
        vms.post(":id", "restart", use: restart)
        vms.post(":id", "detach-iso", use: detachISO)
        vms.post(":id", "attach-iso", use: attachISO)
        vms.get(":id", "state", use: stateStream)
        vms.get(":id", "guest-info", use: getGuestInfo)
    }

    // MARK: - CRUD

    @Sendable
    func list(req: Vapor.Request) async throws -> [VMResponse] {
        let (limit, offset) = req.pagination()
        let vms = try await req.db.read { db in
            try VM.limit(limit, offset: offset).fetchAll(db)
        }
        return vms.map { VMResponse(from: $0) }
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return VMResponse(from: vm)
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> Response {
        try CreateVMRequest.validate(content: req)
        let body = try req.content.decode(CreateVMRequest.self)

        let params = CreateVMParams(
            name: body.name, vmType: body.vmType, cpuCount: body.cpuCount,
            memoryMB: body.memoryMB, diskSizeGB: body.diskSizeGB, isoId: body.isoId,
            cloudImageId: body.cloudImageId, cloudInit: body.cloudInit,
            networkId: body.networkId, existingDiskId: body.existingDiskId,
            sharedPaths: body.sharedPaths, portForwards: body.portForwards,
            usbDevices: body.usbDevices,
            description: body.description, bootOrder: body.bootOrder,
            displayResolution: body.displayResolution, uefi: body.uefi,
            tpmEnabled: body.tpmEnabled,
        )
        let result = try await VMLifecycleService.createVM(
            params: params, db: req.db, backgroundTasks: backgroundTasks,
        )

        switch result {
        case let .created(vm):
            AuditService.log(
                action: "vm.create", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            let data = try JSONEncoder().encode(VMResponse(from: vm))
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: data))

        case let .provisioning(taskID, vm):
            AuditService.log(
                action: "vm.create", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            let response = VMTaskAcceptedResponse(taskID: taskID, vm: VMResponse(from: vm))
            let data = try JSONEncoder().encode(response)
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .accepted, headers: headers, body: .init(data: data))
        }
    }

    @Sendable
    func update(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try UpdateVMRequest.validate(content: req)
        let body = try req.content.decode(UpdateVMRequest.self)

        let updateParams = UpdateVMParams(
            name: body.name, cpuCount: body.cpuCount, memoryMB: body.memoryMB,
            networkId: body.networkId, portForwards: body.portForwards,
            usbDevices: body.usbDevices,
            description: body.description, bootOrder: body.bootOrder,
            displayResolution: body.displayResolution, additionalDiskIds: body.additionalDiskIds,
            sharedPaths: body.sharedPaths, uefi: body.uefi, tpmEnabled: body.tpmEnabled,
        )
        let vm = try await VMLifecycleService.updateVM(
            id: id, params: updateParams, db: req.db,
        )

        AuditService.log(
            action: "vm.update", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
        )
        return VMResponse(from: vm)
    }

    @Sendable
    func delete(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let keepDisk = (try? req.query.get(Bool.self, at: "keepDisk")) ?? false

        let (taskID, vmName) = try await VMLifecycleService.deleteVM(
            id: id, keepDisk: keepDisk, vmManager: vmManager,
            backgroundTasks: backgroundTasks, db: req.db,
        )

        AuditService.log(
            action: "vm.delete", resourceType: "vm", resourceId: id, resourceName: vmName, req: req,
        )

        let response = TaskAcceptedResponse(taskID: taskID)
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .accepted, headers: headers, body: .init(data: data))
    }

    // MARK: - Lifecycle

    @Sendable
    func start(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try await vmManager.start(vmID: id)
        AuditService.log(action: "vm.start", resourceType: "vm", resourceId: id, req: req)
        return .noContent
    }

    @Sendable
    func stop(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try? req.content.decode(StopVMRequest.self)
        let allowedMethods: Set = ["acpi", "force"]
        let method = body?.method ?? (body?.force == true ? "force" : "acpi")
        guard allowedMethods.contains(method) else {
            throw Abort(.badRequest, reason: "Invalid stop method. Must be one of: acpi, force")
        }
        try await vmManager.stop(vmID: id, force: body?.force ?? false, method: method)
        let detailJSON =
            try String(data: JSONEncoder().encode(["method": method]), encoding: .utf8) ?? "{}"
        AuditService.log(
            action: "vm.stop", resourceType: "vm", resourceId: id, detail: detailJSON, req: req,
        )
        return .noContent
    }

    @Sendable
    func restart(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try await vmManager.restart(vmID: id)
        AuditService.log(action: "vm.restart", resourceType: "vm", resourceId: id, req: req)
        return .noContent
    }

    struct DetachISORequest: Content {
        let isoId: String?
    }

    @Sendable
    func detachISO(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try? req.content.decode(DetachISORequest.self)
        try await vmManager.detachISO(vmID: id, isoId: body?.isoId)
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return VMResponse(from: vm)
    }

    struct AttachISORequest: Content {
        let isoId: String
    }

    @Sendable
    func attachISO(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try req.content.decode(AttachISORequest.self)
        try await vmManager.attachISO(vmID: id, isoId: body.isoId)
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        AuditService.log(action: "vm.attach-iso", resourceType: "vm", resourceId: id, req: req)
        return VMResponse(from: vm)
    }

    // MARK: - Guest Info

    @Sendable
    func getGuestInfo(req: Vapor.Request) async throws -> GuestInfoResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let result = try await VMLifecycleService.getGuestInfo(
            vmID: id, vmManager: vmManager, db: req.db,
        )
        return GuestInfoResponse(from: result)
    }

    // MARK: - SSE State Stream

    @Sendable
    func stateStream(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }

        guard try await req.db.read({ db in try VM.fetchOne(db, key: id) }) != nil else {
            throw Abort(.notFound)
        }

        let headers = HTTPHeaders([
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
        ])

        let stream = await stateStreamService.stateStream(vmID: id)
        let encoder = JSONEncoder()

        return Response(
            status: .ok, headers: headers,
            body: .init(asyncStream: { writer in
                do {
                    let merged = AsyncStream<String> { continuation in
                        let eventTask = Task {
                            for await event in stream {
                                if let data = try? encoder.encode(event),
                                   let json = String(data: data, encoding: .utf8) {
                                    continuation.yield("data: \(json)\n\n")
                                }
                            }
                            continuation.finish()
                        }
                        let keepaliveTask = Task {
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 15_000_000_000)
                                guard !Task.isCancelled else { break }
                                continuation.yield(": keepalive\n\n")
                            }
                        }
                        continuation.onTermination = { _ in
                            eventTask.cancel()
                            keepaliveTask.cancel()
                        }
                    }

                    for await chunk in merged {
                        try await writer.write(.buffer(.init(string: chunk)))
                    }
                    try await writer.write(.end)
                } catch {
                    let isBrokenPipe = "\(error)".contains("Broken pipe")
                    if !isBrokenPipe {
                        Log.vm.error("VM state stream error for \(id): \(error)", vm: id)
                    }
                    try? await writer.write(.end)
                }
            }),
        )
    }
}
