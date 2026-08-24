import Foundation

/// Validated Workload after document-or-record intake.
///
/// `portable` is what we persist (columns + overrides). `resolved` is the host
/// overlay applied on top. Guest-type is one step: existing `GuestProfiles` via
/// `WorkloadSpecProjector.resolveGuestType` / `WorkloadSpecResolver.launchGuestType`.
public struct EffectiveWorkload: Equatable, Sendable {
    public var portable: WorkloadSpec
    public var resolved: WorkloadSpec
    public var portableGuestType: String
    public var launchGuestType: String
    public var accelerator: String?
    public var hugepages: Bool
    /// Decoded `vms.specJson` when the input was a record. Nil when absent.
    public var storedDocument: WorkloadSpec?
}

/// Create-only fields that are not WorkloadSpec (disk image size, Library image).
public struct CreateWorkloadExtras: Sendable {
    public var diskSizeGB: Int?
    public var isoId: String?
    public var cloudImageId: String?
    public var cloudInit: CloudInitConfig?
    public var networkId: String?
    public var existingDiskId: String?
    public var sharedPaths: [String]?
    public var portForwards: [PortForwardRule]?
    public var usbDevices: [USBPassthroughDevice]?
    public var gpuDevices: [GPUPassthroughDevice]?
    public var description: String?
    public var bootOrder: String?
    public var displayResolution: String?
    public var uefi: Bool?
    public var tpmEnabled: Bool?
    /// Apply/create from a document must have boot disk or ISO media.
    public var requireBootMedia: Bool
    /// When an ISO is present and `diskSizeGB` is omitted (declarative apply).
    public var defaultISODiskSizeGB: Int?

    public init(
        diskSizeGB: Int? = nil,
        isoId: String? = nil,
        cloudImageId: String? = nil,
        cloudInit: CloudInitConfig? = nil,
        networkId: String? = nil,
        existingDiskId: String? = nil,
        sharedPaths: [String]? = nil,
        portForwards: [PortForwardRule]? = nil,
        usbDevices: [USBPassthroughDevice]? = nil,
        gpuDevices: [GPUPassthroughDevice]? = nil,
        description: String? = nil,
        bootOrder: String? = nil,
        displayResolution: String? = nil,
        uefi: Bool? = nil,
        tpmEnabled: Bool? = nil,
        requireBootMedia: Bool = false,
        defaultISODiskSizeGB: Int? = nil,
    ) {
        self.diskSizeGB = diskSizeGB
        self.isoId = isoId
        self.cloudImageId = cloudImageId
        self.cloudInit = cloudInit
        self.networkId = networkId
        self.existingDiskId = existingDiskId
        self.sharedPaths = sharedPaths
        self.portForwards = portForwards
        self.usbDevices = usbDevices
        self.gpuDevices = gpuDevices
        self.description = description
        self.bootOrder = bootOrder
        self.displayResolution = displayResolution
        self.uefi = uefi
        self.tpmEnabled = tpmEnabled
        self.requireBootMedia = requireBootMedia
        self.defaultISODiskSizeGB = defaultISODiskSizeGB
    }

    public static var apply: CreateWorkloadExtras {
        CreateWorkloadExtras(
            requireBootMedia: true,
            defaultISODiskSizeGB: WorkloadApplyService.defaultCreateDiskSizeGB,
        )
    }
}

/// One pipeline: document or VM record → validated effective Workload.
///
/// Projector (columns ↔ spec) and Resolver (host overlay) stay; this is the
/// only intake. `specJson` is read here as `storedDocument`.
public enum EffectiveWorkloadPipeline {
    /// Overlay merge + guest-type. Does not re-run write validation (launch path).
    public static func resolve(
        _ spec: WorkloadSpec,
        host: WorkloadSpecResolver.HostPlatform = .current,
    ) throws -> EffectiveWorkload {
        let merged = WorkloadSpecResolver.resolve(spec, host: host)
        let portableGuestType = try WorkloadSpecProjector.resolveGuestType(spec)
        let launchGuestType = try WorkloadSpecResolver.launchGuestType(spec, host: host)
        return EffectiveWorkload(
            portable: spec,
            resolved: merged.spec,
            portableGuestType: portableGuestType,
            launchGuestType: launchGuestType,
            accelerator: merged.accelerator,
            hugepages: merged.hugepages,
            storedDocument: nil,
        )
    }

    /// Validate then resolve. Use for documents and create.
    public static func evaluate(
        _ spec: WorkloadSpec,
        existingID: String? = nil,
        storedDocument: WorkloadSpec? = nil,
        host: WorkloadSpecResolver.HostCapabilities = .current,
    ) throws -> EffectiveWorkload {
        try WorkloadSpecProjector.validate(spec, existingID: existingID)
        // validate() already applied current-host overlay checks; resolve uses platform.
        var effective = try resolve(spec, host: host.platform)
        effective.storedDocument = storedDocument
        return effective
    }

    /// Parse/merge a document onto an optional live record, then evaluate.
    public static func evaluate(
        document: [String: Any],
        existing: VM? = nil,
        host: WorkloadSpecResolver.HostCapabilities = .current,
    ) throws -> EffectiveWorkload {
        if let existing {
            let merged = try WorkloadSpecDocument.merge(
                base: WorkloadSpecProjector.fromVM(existing),
                overlay: document,
            )
            return try evaluate(merged, existingID: existing.id, host: host)
        }
        let spec = try WorkloadSpecDocument.decode(document)
        return try evaluate(spec, host: host)
    }

    /// Columns are source of truth. `specJson` is the stored document when it decodes.
    public static func evaluate(vm: VM) throws -> EffectiveWorkload {
        let portable = WorkloadSpecProjector.fromVM(vm)
        var effective = try resolve(portable)
        effective.storedDocument = WorkloadSpecJSON.decode(vm.specJson)
        return effective
    }

    /// Flat create (name + cpu + memory, no spec object) as a WorkloadSpec.
    public static func specFromFlat(
        name: String,
        vmType: String?,
        osFamily: String?,
        cpuCount: Int,
        memoryMB: Int,
        description: String? = nil,
        bootOrder: String? = nil,
        displayResolution: String? = nil,
        uefi: Bool? = nil,
        tpmEnabled: Bool? = nil,
        networkId: String? = nil,
        existingDiskId: String? = nil,
        isoId: String? = nil,
        sharedPaths: [String]? = nil,
        portForwards: [PortForwardRule]? = nil,
        usbDevices: [USBPassthroughDevice]? = nil,
        gpuDevices: [GPUPassthroughDevice]? = nil,
        workloadClass: String? = nil,
    ) throws -> WorkloadSpec {
        let guestType = try flatGuestType(vmType: vmType, osFamily: osFamily)
        var disks: [WorkloadDisk] = []
        if let boot = existingDiskId, !boot.isEmpty {
            disks.append(WorkloadDisk(role: "boot", diskId: boot, bus: "virtio"))
        }
        if let iso = isoId, !iso.isEmpty {
            disks.append(WorkloadDisk(role: "cdrom", imageId: iso))
        }
        let forwards = (portForwards ?? []).map {
            WorkloadPortForward(hostPort: $0.hostPort, guestPort: $0.guestPort, proto: $0.protocol)
        }
        let network = WorkloadNetwork(
            mode: networkId == nil ? NetworkMode.nat.rawValue : nil,
            networkId: networkId,
            portForwards: forwards,
        )
        let usb = (usbDevices ?? []).map { USBPassthroughService.workload(from: $0) }
        let gpu = (gpuDevices ?? []).map { GPUPassthroughService.workload(from: $0) }
        // Leave firmware nil so omitted uefi/tpmEnabled stay omitted on CreateVMParams.
        // Synthesizing tpm: false here overrode the Windows default in buildVM.
        return WorkloadSpec(
            metadata: WorkloadMetadata(name: name, description: description),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: cpuCount, memoryMb: memoryMB),
                guestType: guestType,
                bootOrder: bootOrder,
                disks: disks,
                networks: [network],
                usb: usb,
                gpu: gpu,
                display: displayResolution.map { WorkloadDisplay(resolution: $0) },
                sharedPaths: sharedPaths,
                workloadClass: workloadClass,
            ),
        )
    }

    public static func flatGuestType(vmType: String?, osFamily: String?) throws -> String {
        if let vmType, !vmType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try GuestProfiles.require(vmType).id
        }
        return try GuestProfiles.defaultID(osFamily: osFamily)
    }

    public static func createParams(
        from spec: WorkloadSpec,
        extras: CreateWorkloadExtras = CreateWorkloadExtras(),
    ) throws -> CreateVMParams {
        let effective = try evaluate(spec)
        return try createParams(from: effective, extras: extras)
    }

    /// Map the **portable** spec to create params (overrides stay on the bag).
    public static func createParams(
        from effective: EffectiveWorkload,
        extras: CreateWorkloadExtras = CreateWorkloadExtras(),
    ) throws -> CreateVMParams {
        let spec = effective.portable
        let bootDiskId = spec.spec.disks.first(where: { $0.role == "boot" })?.diskId
        let isoFromSpec = spec.spec.disks.first(where: { $0.role == "cdrom" })?.imageId
            ?? spec.spec.disks.first(where: { $0.role == "cdrom" })?.diskId
        let isoId = extras.isoId ?? isoFromSpec
        if extras.requireBootMedia {
            if bootDiskId == nil || bootDiskId?.isEmpty == true,
               isoId == nil || isoId?.isEmpty == true {
                throw BarkVisorError.badRequest(
                    "Creating a workload requires spec.disks with a boot diskId or a cdrom imageId",
                )
            }
        }
        let diskSizeGB = extras.diskSizeGB
            ?? (isoId == nil ? nil : extras.defaultISODiskSizeGB)
        let forwards = spec.spec.networks.first?.portForwards.map {
            PortForwardRule(protocol: $0.proto, hostPort: $0.hostPort, guestPort: $0.guestPort)
        }
        let usb = spec.spec.usb.map { USBPassthroughService.passthrough(from: $0) }
        let gpu = spec.spec.gpu.map { GPUPassthroughService.passthrough(from: $0) }
        let requestedID = spec.metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateVMParams(
            id: requestedID?.isEmpty == true ? nil : requestedID,
            name: spec.metadata.name,
            vmType: effective.portableGuestType,
            cpuCount: spec.spec.resources.cpu,
            memoryMB: spec.spec.resources.memoryMb,
            diskSizeGB: diskSizeGB,
            isoId: isoId,
            cloudImageId: extras.cloudImageId,
            cloudInit: extras.cloudInit ?? cloudInitConfig(from: spec.spec.cloudInit),
            networkId: extras.networkId ?? spec.spec.networks.first?.networkId,
            existingDiskId: extras.existingDiskId ?? bootDiskId,
            sharedPaths: extras.sharedPaths ?? spec.spec.sharedPaths,
            portForwards: extras.portForwards ?? forwards,
            usbDevices: extras.usbDevices ?? (usb.isEmpty ? nil : usb),
            gpuDevices: extras.gpuDevices ?? (gpu.isEmpty ? nil : gpu),
            description: extras.description ?? spec.metadata.description,
            bootOrder: extras.bootOrder ?? spec.spec.bootOrder,
            displayResolution: extras.displayResolution ?? spec.spec.display?.resolution,
            uefi: extras.uefi ?? spec.spec.firmware?.uefi,
            tpmEnabled: extras.tpmEnabled ?? spec.spec.firmware?.tpm,
            overrides: spec.overrides,
            health: spec.spec.health,
            workloadClass: spec.spec.workloadClass,
        )
    }

    /// `spec.cloudInit.inline` is user-data for ISO generation.
    public static func cloudInitConfig(from cloud: WorkloadCloudInit?) -> CloudInitConfig? {
        guard let inline = cloud?.inline,
              !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CloudInitConfig(sshAuthorizedKeys: nil, userData: inline)
    }
}
