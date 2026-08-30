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
    let guestAddressing: GuestAddressing?
    let sharedPaths: [String]?
    let portForwards: [PortForwardRule]?
    let usbDevices: [USBPassthroughDevice]?
    let gpuDevices: [GPUPassthroughDevice]?
    let pendingChanges: Bool
    let workloadClass: String
    let startOnBoot: Bool
    let session: CodingAgentSessionView?
    let createdAt: String
    let updatedAt: String
    let pendingImageId: String?
    let downloadPercent: Int?
    let creationProgress: WorkloadCreationProgress

    init(
        from vm: VM,
        signals: WorkloadHealthSignals = .unobserved,
        pendingImageId: String? = nil,
        downloadPercent: Int? = nil,
        lastProgress: ImageProgressEvent? = nil,
        provisionTaskStatus: BackgroundTaskManager.TaskStatus? = nil,
        imageStatus: String? = nil,
    ) {
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
        self.guestAddressing = vm.decodedGuestAddressing
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
        let gpu = vm.decodedGPUDevices
        self.gpuDevices = gpu.isEmpty ? nil : gpu
        self.workloadClass = (try? WorkloadClass.parse(vm.workloadClass).rawValue)
            ?? WorkloadClass.house.rawValue
        self.startOnBoot = vm.startOnBoot
        if let session = vm.decodedSession {
            self.session = CodingAgentLifecycle.view(session, now: Date(), vmState: vm.state)
        } else {
            self.session = nil
        }
        self.pendingImageId = pendingImageId
        self.downloadPercent = downloadPercent
        let overlay = pendingImageId.map {
            PendingVMImageOverlay(
                pendingImageId: $0,
                downloadPercent: downloadPercent,
                imageStatus: imageStatus,
            )
        }
        self.creationProgress = WorkloadCreationProgressProjector.project(
            vmState: vm.state,
            overlay: overlay,
            lastProgress: lastProgress,
            provisionTaskStatus: provisionTaskStatus,
            imageStatus: imageStatus,
        )
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
    let guestAddressing: GuestAddressing? = nil
    let networkId: String?
    let existingDiskId: String?
    let sharedPaths: [String]?
    let portForwards: [PortForwardRule]?
    let usbDevices: [USBPassthroughDevice]?
    let gpuDevices: [GPUPassthroughDevice]?
    let description: String?
    let bootOrder: String?
    let displayResolution: String?
    let uefi: Bool?
    let tpmEnabled: Bool?
    /// Optional WorkloadSpec. When present, it is the source for identity/resources.
    let spec: WorkloadSpec?
    /// `house` | `agent`. Omitted = house (PAS-268).
    var workloadClass: String?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1 ... 128), required: false)
        validations.add(
            "vmType",
            as: String.self,
            is: .in(GuestProfiles.supportedIDs),
            required: false,
        )
        validations.add(
            "cpuCount",
            as: Int.self,
            is: .range(1 ... PlatformHost.cpuCount),
            required: false,
        )
        validations.add(
            "memoryMB",
            as: Int.self,
            is: .range(128 ... PlatformHost.physicalMemoryMB),
            required: false,
        )
    }
}

/// CloudInitConfig moved to BarkVisorCore
extension CloudInitConfig: Content {}
extension GuestAddressing: Content {}

struct UpdateVMRequest: Content, Validatable {
    let name: String?
    let cpuCount: Int?
    let memoryMB: Int?
    let networkId: String?
    let portForwards: [PortForwardRule]?
    let usbDevices: [USBPassthroughDevice]?
    let gpuDevices: [GPUPassthroughDevice]?
    let description: String?
    let bootOrder: String?
    let displayResolution: String?
    let additionalDiskIds: [String]?
    let sharedPaths: [String]?
    let uefi: Bool?
    let tpmEnabled: Bool?
    let spec: WorkloadSpec?
    var workloadClass: String?
    var startOnBoot: Bool?
    let guestAddressing: GuestAddressing? = nil

    static func validations(_ validations: inout Validations) {
        validations.add(
            "cpuCount",
            as: Int?.self,
            is: .nil || .range(1 ... PlatformHost.cpuCount),
            required: false,
        )
        validations.add(
            "memoryMB",
            as: Int?.self,
            is: .nil || .range(128 ... PlatformHost.physicalMemoryMB),
            required: false,
        )
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
    let listeningPorts: [GuestListeningPortDTO]?
    let portsCollectedAt: String?

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
        self.listeningPorts = r.listeningPorts
        self.portsCollectedAt = r.portsCollectedAt
    }
}

// MARK: - Controller

struct VMController: RouteCollection {
    let vmManager: VMManager
    let qmpDiskService: QMPDiskService
    let metricsCollector: MetricsCollector
    let stateStreamService: VMStateStreamService
    let backgroundTasks: BackgroundTaskManager
    let healthProbes: HealthProbeService
    let imageDownloader: ImageDownloader

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
        vms.post(":id", "session", "resume", use: resumeSession)
        vms.post(":id", "session", "reset", use: resetSession)
        vms.post(":id", "session", "burn", use: burnSession)
        vms.post(":id", "detach-iso", use: detachISO)
        vms.post(":id", "attach-iso", use: attachISO)
        vms.post(":id", "usb", use: attachUSB)
        vms.delete(":id", "usb", ":deviceId", use: detachUSB)
        vms.post(":id", "gpu", use: attachGPU)
        vms.delete(":id", "gpu", ":deviceId", use: detachGPU)
        vms.get(":id", "state", use: stateStream)
        vms.get(":id", "events", use: events)
        vms.get(":id", "guest-info", use: getGuestInfo)
        vms.get(":id", "health", use: getHealth)
        vms.put(":id", "health", use: putHealth)
        vms.post(":id", "health", "probe", use: probeHealth)
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
                VMTaskAcceptedResponse(
                    taskID: taskID,
                    vm: VMResponse(from: vm, provisionTaskStatus: .running),
                ),
                status: .accepted,
            )
        }
    }

    @Sendable
    func update(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try UpdateVMRequest.validate(content: req)
        let body = try req.content.decode(UpdateVMRequest.self)

        var vm: VM
        if var spec = body.spec {
            if spec.spec.workloadClass == nil {
                spec.spec.workloadClass = body.workloadClass
            }
            vm = try await VMLifecycleService.updateVMSpec(id: id, spec: spec, db: req.db)
            if let startOnBoot = body.startOnBoot, startOnBoot != vm.startOnBoot {
                vm = try await VMLifecycleService.updateVM(
                    id: id,
                    params: UpdateVMParams(startOnBoot: startOnBoot),
                    db: req.db,
                )
            }
        } else {
            let updateParams = UpdateVMParams(
                name: body.name, cpuCount: body.cpuCount, memoryMB: body.memoryMB,
                networkId: body.networkId, portForwards: body.portForwards,
                usbDevices: body.usbDevices,
                gpuDevices: body.gpuDevices,
                description: body.description, bootOrder: body.bootOrder,
                displayResolution: body.displayResolution, additionalDiskIds: body.additionalDiskIds,
                sharedPaths: body.sharedPaths, uefi: body.uefi, tpmEnabled: body.tpmEnabled,
                workloadClass: body.workloadClass, startOnBoot: body.startOnBoot,
                guestAddressing: body.guestAddressing,
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
        AuditService.log(action: VMLifecycleAction.started, resourceType: "vm", resourceId: id, req: req)
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
            action: VMLifecycleAction.stopped, resourceType: "vm", resourceId: id, detail: detailJSON,
            req: req,
        )
        return .noContent
    }

    @Sendable
    func restart(req: Vapor.Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try await vmManager.restart(vmID: id)
        AuditService.log(action: VMLifecycleAction.restarted, resourceType: "vm", resourceId: id, req: req)
        return .noContent
    }

    @Sendable
    func events(req: Vapor.Request) async throws -> [AuditEntry] {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        return try await AuditService.vmEvents(vmID: id, db: req.db)
    }

    @Sendable
    func resumeSession(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try await CodingAgentLifecycleService.resume(vmID: id, vmManager: vmManager, db: req.db)
        AuditService.log(action: "vm.session.resume", resourceType: "vm", resourceId: id, req: req)
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return try await respond(vm, db: req.db)
    }

    @Sendable
    func resetSession(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        try await CodingAgentLifecycleService.reset(vmID: id, vmManager: vmManager, db: req.db)
        AuditService.log(action: "vm.session.reset", resourceType: "vm", resourceId: id, req: req)
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return try await respond(vm, db: req.db)
    }

    @Sendable
    func burnSession(req: Vapor.Request) async throws -> Response {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let (taskID, vmName) = try await CodingAgentLifecycleService.burn(
            vmID: id, vmManager: vmManager, backgroundTasks: backgroundTasks, db: req.db,
        )
        AuditService.log(
            action: "vm.session.burn", resourceType: "vm", resourceId: id, resourceName: vmName,
            req: req,
        )
        return try Response.json(TaskAcceptedResponse(taskID: taskID), status: .accepted)
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

    struct AttachUSBRequest: Content {
        let deviceId: String
    }

    @Sendable
    func attachUSB(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try req.content.decode(AttachUSBRequest.self)
        let vm = try await VMLifecycleService.attachUSB(vmID: id, deviceId: body.deviceId, db: req.db)
        AuditService.log(
            action: "vm.usb.attach", resourceType: "vm", resourceId: vm.id, resourceName: vm.name,
            req: req,
        )
        return try await respond(vm, db: req.db)
    }

    @Sendable
    func detachUSB(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let deviceId = req.parameters.get("deviceId") else { throw Abort(.badRequest) }
        let decoded = deviceId.removingPercentEncoding ?? deviceId
        let vm = try await VMLifecycleService.detachUSB(vmID: id, deviceId: decoded, db: req.db)
        AuditService.log(
            action: "vm.usb.detach", resourceType: "vm", resourceId: vm.id, resourceName: vm.name,
            req: req,
        )
        return try await respond(vm, db: req.db)
    }

    struct AttachGPURequest: Content {
        let deviceId: String
    }

    @Sendable
    func attachGPU(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try req.content.decode(AttachGPURequest.self)
        let vm = try await VMLifecycleService.attachGPU(vmID: id, deviceId: body.deviceId, db: req.db)
        AuditService.log(
            action: "vm.gpu.attach", resourceType: "vm", resourceId: vm.id, resourceName: vm.name,
            req: req,
        )
        return try await respond(vm, db: req.db)
    }

    @Sendable
    func detachGPU(req: Vapor.Request) async throws -> VMResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let deviceId = req.parameters.get("deviceId") else { throw Abort(.badRequest) }
        let decoded = deviceId.removingPercentEncoding ?? deviceId
        let vm = try await VMLifecycleService.detachGPU(vmID: id, deviceId: decoded, db: req.db)
        AuditService.log(
            action: "vm.gpu.detach", resourceType: "vm", resourceId: vm.id, resourceName: vm.name,
            req: req,
        )
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

    /// Flat create: same keys as wizard and WorkloadSpec (`GuestProfiles.resolve`).
    static func resolveFlatGuestType(
        vmType: String?,
        osFamily: String?,
        arch: String? = nil,
    ) throws -> String {
        try GuestProfiles.resolve(guestType: vmType, osFamily: osFamily, arch: arch)
    }

    static func createParams(from body: CreateVMRequest) throws -> CreateVMParams {
        let extras = CreateWorkloadExtras(
            diskSizeGB: body.diskSizeGB,
            isoId: body.isoId,
            cloudImageId: body.cloudImageId,
            cloudInit: body.cloudInit,
            networkId: body.networkId,
            existingDiskId: body.existingDiskId,
            sharedPaths: body.sharedPaths,
            portForwards: body.portForwards,
            usbDevices: body.usbDevices,
            gpuDevices: body.gpuDevices,
            description: body.description,
            bootOrder: body.bootOrder,
            displayResolution: body.displayResolution,
            uefi: body.uefi,
            tpmEnabled: body.tpmEnabled,
            guestAddressing: body.guestAddressing,
        )
        if var spec = body.spec {
            if spec.spec.workloadClass == nil {
                spec.spec.workloadClass = body.workloadClass
            }
            return try EffectiveWorkloadPipeline.createParams(from: spec, extras: extras)
        }
        guard let name = body.name,
              let cpuCount = body.cpuCount, let memoryMB = body.memoryMB
        else {
            throw BarkVisorError.badRequest(
                "name, cpuCount, and memoryMB are required when spec is omitted",
            )
        }
        let spec = try EffectiveWorkloadPipeline.specFromFlat(
            name: name,
            vmType: body.vmType,
            osFamily: body.osFamily,
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            description: body.description,
            bootOrder: body.bootOrder,
            displayResolution: body.displayResolution,
            uefi: body.uefi,
            tpmEnabled: body.tpmEnabled,
            networkId: body.networkId,
            existingDiskId: body.existingDiskId,
            isoId: body.isoId,
            sharedPaths: body.sharedPaths,
            portForwards: body.portForwards,
            usbDevices: body.usbDevices,
            gpuDevices: body.gpuDevices,
            workloadClass: body.workloadClass,
        )
        return try EffectiveWorkloadPipeline.createParams(from: spec, extras: extras)
    }

    /// `spec.cloudInit.inline` is user-data for ISO generation. `userDataRef` is a
    /// host ISO path and is applied on spec update, not create.
    static func cloudInitConfig(from cloud: WorkloadCloudInit?) -> CloudInitConfig? {
        EffectiveWorkloadPipeline.cloudInitConfig(from: cloud)
    }

    // MARK: - Guest Info

    @Sendable
    func getGuestInfo(req: Vapor.Request) async throws -> GuestInfoResponse {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let result = try await GuestAgentInventory.getGuestInfo(
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
}
