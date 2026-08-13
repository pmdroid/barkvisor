import BarkVisorCore
import Foundation
import GRDB
import Vapor

// MARK: - DTOs

struct VMResponse: Content {
    let spec: WorkloadSpec
    let status: VMRuntimeStatus
    // Flat projections kept for existing clients (PAS-35 dual-read).
    let id: String
    let name: String
    let vmType: String
    let state: String
    let health: WorkloadHealth
    let cpuCount: Int
    let memoryMB: Int
    let bootDiskId: String
    let isoId: String? // first isoIds element
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

    init(from vm: VM, signals: WorkloadHealthSignals = .unobserved) {
        let spec = WorkloadSpecProjector.fromVM(vm)
        self.spec = spec
        let status = WorkloadSpecProjector.status(from: vm, signals: signals)
        self.status = status
        self.id = vm.id
        self.name = vm.name
        self.vmType = vm.vmType
        self.state = vm.state
        self.health = status.health
        self.cpuCount = vm.cpuCount
        self.memoryMB = vm.memoryMb
        self.bootDiskId = vm.bootDiskId
        let decodedIsoIds = vm.decodedISOIds
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
        let disks = vm.decodedAdditionalDiskIds
        self.additionalDiskIds = disks.isEmpty ? nil : disks
        let paths = vm.decodedSharedPaths
        self.sharedPaths = paths.isEmpty ? nil : paths
        let pfs = vm.decodedPortForwards
        self.portForwards = pfs.isEmpty ? nil : pfs
        let usb = vm.decodedUSBDevices
        self.usbDevices = usb.isEmpty ? nil : usb
    }
}

struct CreateVMRequest: Content, Validatable {
    let name: String?
    let vmType: String?
    /// Used when `vmType` is omitted so the server can pick a host-native guest (PAS-93).
    let osFamily: String?
    let cpuCount: Int?
    let memoryMB: Int?
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
    /// Optional WorkloadSpec. When present, it is the source for identity/resources.
    let spec: WorkloadSpec?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1 ... 128), required: false)
        validations.add(
            "vmType",
            as: String.self,
            is: .in("linux-arm64", "windows-arm64", "linux-amd64", "linux-x86_64"),
            required: false,
        )
        validations.add("cpuCount", as: Int.self, is: .range(1 ... 256), required: false)
        validations.add("memoryMB", as: Int.self, is: .range(128 ... 1_048_576), required: false)
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
    let spec: WorkloadSpec?

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
        vms.get(":id", "health", use: getHealth)
        vms.get(":id", "spec", use: getSpec)
        vms.put(":id", "spec", use: putSpec)
    }

    // MARK: - CRUD

    @Sendable
    func list(req: Vapor.Request) async throws -> [VMResponse] {
        let (limit, offset) = req.pagination()
        let vms = try await req.db.read { db in
            try VM.limit(limit, offset: offset).fetchAll(db)
        }
        return try await respond(vms, db: req.db)
    }

    @Sendable
    func get(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return try await respond(vm, db: req.db)
    }

    @Sendable
    func getHealth(req: Vapor.Request) async throws -> WorkloadHealthStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        let lastSeen = try await guestLastSeen(ids: [vm.id], db: req.db)
        let signals = await vmManager.healthSignals(for: vm, lastSeenAt: lastSeen[vm.id])
        return WorkloadHealthProjector.project(
            state: VMState.parse(vm.state),
            signals: signals,
            updatedAt: vm.updatedAt,
        )
    }

    @Sendable
    func create(req: Vapor.Request) async throws -> Response {
        try CreateVMRequest.validate(content: req)
        let body = try req.content.decode(CreateVMRequest.self)
        let params = try Self.createParams(from: body)
        let result = try await VMLifecycleService.createVM(
            params: params, db: req.db, backgroundTasks: backgroundTasks,
        )

        switch result {
        case let .created(vm):
            AuditService.log(
                action: "vm.create", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            return try Response.json(VMResponse(from: vm), status: .ok)

        case let .provisioning(taskID, vm):
            AuditService.log(
                action: "vm.create", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
            )
            return try Response.json(
                VMTaskAcceptedResponse(taskID: taskID, vm: VMResponse(from: vm)),
                status: .accepted,
            )
        }
    }

    @Sendable
    func update(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try UpdateVMRequest.validate(content: req)
        let body = try req.content.decode(UpdateVMRequest.self)

        let vm: VM
        if let spec = body.spec {
            vm = try await VMLifecycleService.updateVMSpec(id: id, spec: spec, db: req.db)
        } else {
            let updateParams = UpdateVMParams(
                name: body.name, cpuCount: body.cpuCount, memoryMB: body.memoryMB,
                networkId: body.networkId, portForwards: body.portForwards,
                usbDevices: body.usbDevices,
                description: body.description, bootOrder: body.bootOrder,
                displayResolution: body.displayResolution, additionalDiskIds: body.additionalDiskIds,
                sharedPaths: body.sharedPaths, uefi: body.uefi, tpmEnabled: body.tpmEnabled,
            )
            vm = try await VMLifecycleService.updateVM(
                id: id, params: updateParams, db: req.db,
            )
        }

        AuditService.log(
            action: "vm.update", resourceType: "vm", resourceId: vm.id, resourceName: vm.name, req: req,
        )
        return try await respond(vm, db: req.db)
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

        return try Response.json(TaskAcceptedResponse(taskID: taskID), status: .accepted)
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
        return try await respond(vm, db: req.db)
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
        return try await respond(vm, db: req.db)
    }

    // MARK: - WorkloadSpec

    @Sendable
    func getSpec(req: Vapor.Request) async throws -> WorkloadSpec {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return WorkloadSpecProjector.fromVM(vm)
    }

    @Sendable
    func putSpec(req: Vapor.Request) async throws -> WorkloadSpec {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let spec = try req.content.decode(WorkloadSpec.self)
        let vm = try await VMLifecycleService.updateVMSpec(id: id, spec: spec, db: req.db)
        AuditService.log(
            action: "vm.spec.update", resourceType: "vm", resourceId: vm.id, resourceName: vm.name,
            req: req,
        )
        return WorkloadSpecProjector.fromVM(vm)
    }

    /// Flat create: honor an explicit `vmType`, otherwise pick a host-native guest.
    static func resolveFlatGuestType(vmType: String?, osFamily: String?) throws -> String {
        if let vmType, !vmType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try GuestProfiles.require(vmType).id
        }
        return try GuestProfiles.defaultID(osFamily: osFamily)
    }

    static func createParams(from body: CreateVMRequest) throws -> CreateVMParams {
        if let spec = body.spec {
            try WorkloadSpecProjector.validate(spec)
            let guestType = try WorkloadSpecProjector.resolveGuestType(spec)
            let bootDiskId = spec.spec.disks.first(where: { $0.role == "boot" })?.diskId
            let isoFromSpec = spec.spec.disks.first(where: { $0.role == "cdrom" })?.imageId
            let forwards = spec.spec.networks.first?.portForwards.map {
                PortForwardRule(protocol: $0.proto, hostPort: $0.hostPort, guestPort: $0.guestPort)
            }
            let usb = spec.spec.usb.map {
                USBPassthroughDevice(vendorId: $0.vendorId, productId: $0.productId, label: $0.label)
            }
            return CreateVMParams(
                name: spec.metadata.name,
                vmType: guestType,
                cpuCount: spec.spec.resources.cpu,
                memoryMB: spec.spec.resources.memoryMb,
                diskSizeGB: body.diskSizeGB,
                isoId: body.isoId ?? isoFromSpec,
                cloudImageId: body.cloudImageId,
                cloudInit: body.cloudInit ?? Self.cloudInitConfig(from: spec.spec.cloudInit),
                networkId: body.networkId ?? spec.spec.networks.first?.networkId,
                existingDiskId: body.existingDiskId ?? bootDiskId,
                sharedPaths: body.sharedPaths ?? spec.spec.sharedPaths,
                portForwards: body.portForwards ?? forwards,
                usbDevices: body.usbDevices ?? (usb.isEmpty ? nil : usb),
                description: body.description ?? spec.metadata.description,
                bootOrder: body.bootOrder ?? spec.spec.bootOrder,
                displayResolution: body.displayResolution ?? spec.spec.display?.resolution,
                uefi: body.uefi ?? spec.spec.firmware?.uefi,
                tpmEnabled: body.tpmEnabled ?? spec.spec.firmware?.tpm,
                overrides: spec.overrides,
            )
        }
        guard let name = body.name,
              let cpuCount = body.cpuCount, let memoryMB = body.memoryMB
        else {
            throw BarkVisorError.badRequest(
                "name, cpuCount, and memoryMB are required when spec is omitted",
            )
        }
        let vmType = try Self.resolveFlatGuestType(vmType: body.vmType, osFamily: body.osFamily)
        return CreateVMParams(
            name: name, vmType: vmType, cpuCount: cpuCount,
            memoryMB: memoryMB, diskSizeGB: body.diskSizeGB, isoId: body.isoId,
            cloudImageId: body.cloudImageId, cloudInit: body.cloudInit,
            networkId: body.networkId, existingDiskId: body.existingDiskId,
            sharedPaths: body.sharedPaths, portForwards: body.portForwards,
            usbDevices: body.usbDevices,
            description: body.description, bootOrder: body.bootOrder,
            displayResolution: body.displayResolution, uefi: body.uefi,
            tpmEnabled: body.tpmEnabled,
        )
    }

    /// `spec.cloudInit.inline` is user-data for ISO generation. `userDataRef` is a
    /// host ISO path and is applied on spec update, not create.
    static func cloudInitConfig(from cloud: WorkloadCloudInit?) -> CloudInitConfig? {
        guard let inline = cloud?.inline,
              !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CloudInitConfig(sshAuthorizedKeys: nil, userData: inline)
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

        let stream = await stateStreamService.stateStream(vmID: id)
        return SSEResponse.stream(from: stream, keepaliveSeconds: 15)
    }

    // MARK: - Health signals

    private func respond(_ vm: VM, db: DatabasePool) async throws -> VMResponse {
        let lastSeen = try await guestLastSeen(ids: [vm.id], db: db)
        let signals = await vmManager.healthSignals(for: vm, lastSeenAt: lastSeen[vm.id])
        return VMResponse(from: vm, signals: signals)
    }

    private func respond(_ vms: [VM], db: DatabasePool) async throws -> [VMResponse] {
        let lastSeen = try await guestLastSeen(ids: vms.map(\.id), db: db)
        var responses: [VMResponse] = []
        responses.reserveCapacity(vms.count)
        for vm in vms {
            let signals = await vmManager.healthSignals(for: vm, lastSeenAt: lastSeen[vm.id])
            responses.append(VMResponse(from: vm, signals: signals))
        }
        return responses
    }

    private func guestLastSeen(ids: [String], db: DatabasePool) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let records = try await db.read { db in
            try GuestInfoRecord.fetchAll(db)
        }
        var seen: [String: String] = [:]
        for record in records where idSet.contains(record.vmId) {
            seen[record.vmId] = record.updatedAt
        }
        return seen
    }
}
