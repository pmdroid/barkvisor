import Foundation

/// Maps `WorkloadSpec` ↔ flat `vms` columns.
///
/// Intake is `EffectiveWorkloadPipeline` (document or record). This type only
/// projects columns. `specJson` is written by `VM.syncSpecProjection` and read
/// by the pipeline as `storedDocument`.
///
/// | spec.path | VM column |
/// |---|---|
/// | metadata.id | id |
/// | metadata.name | name |
/// | metadata.description | description |
/// | spec.guestType | vmType |
/// | spec.arch | GuestProfile.qemuArch (derived) |
/// | spec.resources.cpu | cpuCount |
/// | spec.resources.memoryMb | memoryMb |
/// | spec.firmware.uefi | uefi |
/// | spec.firmware.tpm | tpmEnabled |
/// | spec.bootOrder | bootOrder |
/// | spec.display.resolution | displayResolution |
/// | spec.disks[role=boot].diskId | bootDiskId |
/// | spec.disks[role=data].diskId | additionalDiskIds |
/// | spec.disks[role=cdrom].imageId | isoIds |
/// | spec.networks[0].networkId | networkId |
/// | spec.networks[0].mac | macAddress |
/// | spec.networks[0].portForwards | portForwards |
/// | spec.networks[0].addressing | guestAddressingJson |
/// | spec.cloudInit.userDataRef | cloudInitPath |
/// | spec.usb | usbDevices |
/// | spec.gpu | gpuDevices |
/// | spec.sharedPaths | sharedPaths |
/// | spec.health | healthJson |
/// | spec.workloadClass | workloadClass |
/// | overrides | overridesJson |
///
/// Host-only (status, not required on spec): state, pendingChanges, autoCreated,
/// createdAt, updatedAt, specGeneration, startOnBoot.
public enum WorkloadSpecProjector {
    // MARK: - Read (columns → spec)

    public static func fromVM(_ vm: VM) -> WorkloadSpec {
        let profile = GuestProfiles.profile(for: vm.vmType)
        let boot = WorkloadDisk(role: "boot", diskId: vm.bootDiskId, bus: "virtio")
        let dataDisks = vm.decodedAdditionalDiskIds.map {
            WorkloadDisk(role: "data", diskId: $0, bus: "virtio")
        }
        let cdroms = vm.decodedISOIds.map {
            WorkloadDisk(role: "cdrom", imageId: $0)
        }
        let forwards = vm.decodedPortForwards.map {
            WorkloadPortForward(hostPort: $0.hostPort, guestPort: $0.guestPort, proto: $0.protocol)
        }
        let network = WorkloadNetwork(
            // Implicit NAT when no networkId. Attached records project mode from
            // the Network row at apply/start time (fromVM has no DB).
            mode: vm.networkId == nil ? NetworkMode.nat.rawValue : nil,
            networkId: vm.networkId,
            mac: vm.macAddress,
            portForwards: forwards,
            addressing: vm.decodedGuestAddressing,
        )
        let cloudInit: WorkloadCloudInit? =
            vm.cloudInitPath.map { WorkloadCloudInit(userDataRef: $0) }
        let usb = vm.decodedUSBDevices.map { USBPassthroughService.workload(from: $0) }
        let gpu = vm.decodedGPUDevices.map { GPUPassthroughService.workload(from: $0) }
        let shared = vm.decodedSharedPaths
        return WorkloadSpec(
            metadata: WorkloadMetadata(
                id: vm.id,
                name: vm.name,
                description: vm.description,
            ),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: vm.cpuCount, memoryMb: vm.memoryMb),
                arch: profile?.qemuArch,
                guestType: vm.vmType,
                osFamily: profile?.osFamily,
                machine: profile?.machine,
                firmware: WorkloadFirmware(uefi: vm.uefi, tpm: vm.tpmEnabled),
                bootOrder: vm.bootOrder,
                disks: [boot] + dataDisks + cdroms,
                networks: [network],
                cloudInit: cloudInit,
                usb: usb,
                gpu: gpu,
                display: WorkloadDisplay(resolution: vm.displayResolution),
                sharedPaths: shared.isEmpty ? nil : shared,
                health: vm.decodedHealth,
                workloadClass: (try? WorkloadClass.parse(vm.workloadClass).rawValue)
                    ?? WorkloadClass.house.rawValue,
            ),
            overrides: vm.decodedOverrides,
        )
    }

    public static func status(
        from vm: VM,
        signals: WorkloadHealthSignals = .unobserved,
    ) -> VMRuntimeStatus {
        let health = WorkloadHealthProjector.project(
            state: VMState.parse(vm.state),
            signals: signals,
            updatedAt: vm.updatedAt,
        )
        return VMRuntimeStatus(
            state: VMState.parse(vm.state),
            pendingChanges: vm.pendingChanges,
            generation: vm.specGeneration,
            createdAt: vm.createdAt,
            updatedAt: vm.updatedAt,
            health: health.health,
            healthError: health.lastError,
            backend: WorkloadBackendProjector.project(vm: vm),
            startOnBoot: vm.startOnBoot,
        )
    }

    // MARK: - Write (spec → columns)

    /// Apply spec fields onto an existing VM. Preserves host-only columns.
    public static func apply(_ spec: WorkloadSpec, to vm: inout VM) throws {
        try validate(spec, existingID: vm.id)
        if let bootId = spec.spec.disks.first(where: { $0.role == "boot" })?.diskId,
           bootId != vm.bootDiskId {
            throw BarkVisorError.badRequest("spec update cannot change the boot disk")
        }
        if let ref = spec.spec.cloudInit?.userDataRef {
            try CloudInitService.validateUserDataRef(ref, vmID: vm.id, current: vm.cloudInitPath)
        }
        let guestType = try resolveGuestType(spec)
        vm.name = spec.metadata.name
        vm.description = spec.metadata.description
        vm.vmType = guestType
        vm.cpuCount = spec.spec.resources.cpu
        vm.memoryMb = spec.spec.resources.memoryMb
        vm.uefi = spec.spec.firmware?.uefi ?? vm.uefi
        vm.tpmEnabled = spec.spec.firmware?.tpm ?? vm.tpmEnabled
        if let bootOrder = spec.spec.bootOrder { vm.bootOrder = bootOrder }
        if let resolution = spec.spec.display?.resolution { vm.displayResolution = resolution }

        if let bootId = spec.spec.disks.first(where: { $0.role == "boot" })?.diskId {
            vm.bootDiskId = bootId
        }
        // Empty disks (JSON omit / default []) preserve attachments, matching networks.
        if spec.spec.disks.isEmpty == false {
            let dataIds = spec.spec.disks.compactMap { $0.role == "data" ? $0.diskId : nil }
            vm.setAdditionalDiskIds(dataIds.isEmpty ? nil : dataIds)
            let isoIds = spec.spec.disks.compactMap { $0.role == "cdrom" ? ($0.imageId ?? $0.diskId) : nil }
            vm.setISOIds(isoIds.isEmpty ? nil : isoIds)
        }

        let net = spec.spec.networks.first
        if spec.spec.networks.isEmpty == false {
            vm.networkId = net?.networkId
            vm.macAddress = net?.mac
            let rules = (net?.portForwards ?? []).map {
                PortForwardRule(protocol: $0.proto, hostPort: $0.hostPort, guestPort: $0.guestPort)
            }
            vm.setPortForwards(rules.isEmpty ? nil : rules)
            if let addressing = net?.addressing {
                try vm.setGuestAddressing(addressing.validated())
            } else {
                vm.setGuestAddressing(nil)
            }
        }

        if let cloud = spec.spec.cloudInit {
            vm.cloudInitPath = cloud.userDataRef
        }
        let usb = spec.spec.usb.map { USBPassthroughService.passthrough(from: $0) }
        vm.setUSBDevices(usb.isEmpty ? nil : usb)
        let gpu = spec.spec.gpu.map { GPUPassthroughService.passthrough(from: $0) }
        vm.setGPUDevices(gpu.isEmpty ? nil : gpu)
        if let shared = spec.spec.sharedPaths {
            vm.setSharedPaths(shared.isEmpty ? nil : shared)
        }
        vm.setOverrides(spec.overrides)
        // Always write health: SSA merge keeps omitted fields, so nil here is an
        // explicit `spec.health: null` (or a full spec without health) and must
        // clear persisted probes instead of leaving healthJson in place.
        if let health = spec.spec.health {
            try WorkloadHealthSpec.validate(health)
        }
        vm.setHealth(spec.spec.health)
        vm.workloadClass = try WorkloadClass.parse(spec.spec.workloadClass).rawValue
    }

    public static func validate(_ spec: WorkloadSpec, existingID: String? = nil) throws {
        if spec.apiVersion != WorkloadSpec.currentAPIVersion {
            throw BarkVisorError.badRequest(
                "Unsupported apiVersion \(spec.apiVersion). Expected \(WorkloadSpec.currentAPIVersion)",
            )
        }
        if spec.kind != WorkloadSpec.kindVirtualMachine {
            throw BarkVisorError.badRequest(
                "Unsupported kind \(spec.kind). Expected \(WorkloadSpec.kindVirtualMachine)",
            )
        }
        let name = spec.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 128).contains(name.count) else {
            throw BarkVisorError.badRequest("metadata.name must be 1...128 characters")
        }
        if let existingID, let specID = spec.metadata.id, specID != existingID {
            throw BarkVisorError.badRequest("metadata.id does not match VM \(existingID)")
        }
        try WorkloadSpecResolver.validate(spec)
        let resolved = WorkloadSpecResolver.resolve(spec).spec
        try VMLifecycleService.validateCPUCount(resolved.spec.resources.cpu)
        guard (128 ... 1_048_576).contains(resolved.spec.resources.memoryMb) else {
            throw BarkVisorError.badRequest("spec.resources.memoryMb must be 128...1048576")
        }
        let guestType = try resolveGuestType(resolved)
        try validateMachineAndNetworks(resolved, guestType: guestType)
        for disk in spec.spec.disks {
            guard ["boot", "data", "cdrom"].contains(disk.role) else {
                throw BarkVisorError.badRequest("Unknown disk role '\(disk.role)'")
            }
        }
        for net in spec.spec.networks {
            if let raw = net.mode, !raw.isEmpty {
                let mode = try NetworkCapability.parse(raw)
                try NetworkCapability.requirePortForwardsAllowed(
                    count: net.portForwards.count,
                    mode: mode,
                )
            }
            for rule in net.portForwards {
                guard rule.proto == "tcp" || rule.proto == "udp" else {
                    throw BarkVisorError.badRequest("portForwards.proto must be tcp or udp")
                }
                guard (1 ... 65_535).contains(rule.hostPort), (1 ... 65_535).contains(rule.guestPort)
                else {
                    throw BarkVisorError.badRequest("portForwards ports must be 1...65535")
                }
            }
            try PortRegistry.assertUnique(net.portForwards.map {
                PortForwardRule(protocol: $0.proto, hostPort: $0.hostPort, guestPort: $0.guestPort)
            })
            if let addressing = net.addressing {
                _ = try addressing.validated()
            }
        }
        if let resolution = resolved.spec.display?.resolution {
            _ = try QEMUBuilder.validateResolution(resolution)
        }
        if let health = spec.spec.health {
            try WorkloadHealthSpec.validate(health)
        }
        _ = try WorkloadClass.parse(spec.spec.workloadClass)
        try AgentWorkloadPolicy.validate(spec: spec, network: nil)
    }

    /// PAS-284: `-machine` is a comma-sensitive QEMU arg; builder only attaches networks[0].
    private static func validateMachineAndNetworks(
        _ spec: WorkloadSpec,
        guestType: String,
    ) throws {
        if let machine = spec.spec.machine {
            _ = try QEMUBuilder.validateMachine(
                machine,
                label: "spec.machine",
                guestType: guestType,
            )
        }
        if spec.spec.networks.count > 1 {
            throw BarkVisorError.badRequest(
                "spec.networks supports at most 1 network until multi-NIC is available",
            )
        }
    }

    /// Resolve guest profile id from spec, defaulting arch from the host when omitted.
    public static func resolveGuestType(_ spec: WorkloadSpec) throws -> String {
        try GuestProfiles.resolve(
            guestType: spec.spec.guestType,
            osFamily: spec.spec.osFamily,
            arch: spec.spec.arch,
        )
    }

    public static func normalizeQEMUArch(_ raw: String) -> String? {
        switch PlatformCapabilities.normalizedArch(raw) {
        case "arm64": return "aarch64"
        case "x86_64": return "x86_64"
        default: return nil
        }
    }
}
