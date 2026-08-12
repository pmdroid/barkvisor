import Foundation

/// Maps `WorkloadSpec` ↔ flat `vms` columns.
///
/// Dual-write policy (Wave 0): **read columns → write both** until cutover.
/// `specJson` is a write-aside projection; `fromVM` never reads it.
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
/// | spec.cloudInit.userDataRef | cloudInitPath |
/// | spec.usb | usbDevices |
/// | spec.sharedPaths | sharedPaths |
///
/// Host-only (status, not required on spec): state, pendingChanges, autoCreated,
/// createdAt, updatedAt, specGeneration.
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
        )
        let cloudInit: WorkloadCloudInit? =
            vm.cloudInitPath.map { WorkloadCloudInit(userDataRef: $0) }
        let usb = vm.decodedUSBDevices.map {
            WorkloadUSBDevice(vendorId: $0.vendorId, productId: $0.productId, label: $0.label)
        }
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
                display: WorkloadDisplay(resolution: vm.displayResolution),
                sharedPaths: shared.isEmpty ? nil : shared,
            ),
        )
    }

    public static func status(from vm: VM) -> VMRuntimeStatus {
        VMRuntimeStatus(
            state: VMState.parse(vm.state),
            pendingChanges: vm.pendingChanges,
            generation: vm.specGeneration,
            createdAt: vm.createdAt,
            updatedAt: vm.updatedAt,
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
        }

        if let cloud = spec.spec.cloudInit {
            vm.cloudInitPath = cloud.userDataRef
        }
        let usb = spec.spec.usb.map {
            USBPassthroughDevice(vendorId: $0.vendorId, productId: $0.productId, label: $0.label)
        }
        vm.setUSBDevices(usb.isEmpty ? nil : usb)
        if let shared = spec.spec.sharedPaths {
            vm.setSharedPaths(shared.isEmpty ? nil : shared)
        }
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
        try VMLifecycleService.validateCPUCount(spec.spec.resources.cpu)
        guard (128 ... 1_048_576).contains(spec.spec.resources.memoryMb) else {
            throw BarkVisorError.badRequest("spec.resources.memoryMb must be 128...1048576")
        }
        _ = try resolveGuestType(spec)
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
        }
        if let resolution = spec.spec.display?.resolution {
            _ = try QEMUBuilder.validateResolution(resolution)
        }
    }

    /// Resolve guest profile id from spec, defaulting arch from the host when omitted.
    public static func resolveGuestType(_ spec: WorkloadSpec) throws -> String {
        if let guestType = spec.spec.guestType, !guestType.isEmpty {
            let profile = try GuestProfiles.require(guestType)
            if let arch = spec.spec.arch.flatMap({ Self.normalizeQEMUArch($0) }),
               arch != profile.qemuArch {
                throw BarkVisorError.badRequest(
                    "spec.arch \(arch) does not match guestType \(guestType) (\(profile.qemuArch))",
                )
            }
            return guestType
        }
        let qemuArch = spec.spec.arch.flatMap { Self.normalizeQEMUArch($0) }
            ?? PlatformCapabilities.defaultGuestArch
        let imageArch = qemuArch == "aarch64" ? "arm64" : "x86_64"
        return try GuestProfiles.defaultID(osFamily: spec.spec.osFamily, imageArch: imageArch)
    }

    public static func normalizeQEMUArch(_ raw: String) -> String? {
        switch PlatformCapabilities.normalizedArch(raw) {
        case "arm64": return "aarch64"
        case "x86_64": return "x86_64"
        default: return nil
        }
    }
}
