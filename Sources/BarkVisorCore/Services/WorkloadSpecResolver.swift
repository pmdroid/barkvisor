import Foundation

/// Deep-merges `overrides.linux` / `overrides.macos` onto a portable spec.
///
/// Merge rules (PAS-41):
/// - Only the bag matching the target host OS is applied.
/// - Object fields are deep-merged; omitted overlay fields keep the base value.
/// - Raw QEMU argv is never accepted.
/// - Validation is capability-gated and reports field paths.
public enum WorkloadSpecResolver {
    public enum HostPlatform: String, Sendable {
        case linux
        case macos

        public static var current: HostPlatform {
            #if os(Linux)
                .linux
            #else
                .macos
            #endif
        }
    }

    public struct HostCapabilities: Sendable {
        public var platform: HostPlatform
        public var kvmPresent: Bool
        public var hugepagesPresent: Bool

        public init(platform: HostPlatform, kvmPresent: Bool, hugepagesPresent: Bool) {
            self.platform = platform
            self.kvmPresent = kvmPresent
            self.hugepagesPresent = hugepagesPresent
        }

        public static var current: HostCapabilities {
            HostCapabilities(
                platform: .current,
                kvmPresent: FileManager.default.fileExists(atPath: "/dev/kvm"),
                hugepagesPresent: FileManager.default.fileExists(atPath: "/dev/hugepages"),
            )
        }
    }

    public struct ResolvedWorkload: Equatable, Sendable {
        public var spec: WorkloadSpec
        public var accelerator: String?
        public var hugepages: Bool
    }

    public static func hostOverlay(
        _ spec: WorkloadSpec,
        host: HostPlatform = .current,
    ) -> WorkloadSpecOverlay? {
        let overlay: WorkloadSpecOverlay? = switch host {
        case .linux: spec.overrides?.linux
        case .macos: spec.overrides?.macos
        }
        guard let overlay, !overlay.isEmpty else { return nil }
        return overlay
    }

    /// Merge the host-matching overlay into `spec`. The other bag is ignored.
    public static func resolve(
        _ spec: WorkloadSpec,
        host: HostPlatform = .current,
    ) -> ResolvedWorkload {
        guard let overlay = hostOverlay(spec, host: host) else {
            return ResolvedWorkload(spec: spec, accelerator: nil, hugepages: false)
        }
        var merged = spec
        merged.spec = merge(spec.spec, with: overlay)
        return ResolvedWorkload(
            spec: merged,
            accelerator: overlay.accelerator,
            hugepages: overlay.hugepages ?? false,
        )
    }

    public static func merge(
        _ base: WorkloadSpecBody,
        with overlay: WorkloadSpecOverlay,
    ) -> WorkloadSpecBody {
        var out = base
        if let resources = overlay.resources {
            if let cpu = resources.cpu { out.resources.cpu = cpu }
            if let memoryMb = resources.memoryMb { out.resources.memoryMb = memoryMb }
        }
        if let arch = overlay.arch { out.arch = arch }
        if let guestType = overlay.guestType { out.guestType = guestType }
        if let osFamily = overlay.osFamily { out.osFamily = osFamily }
        if let machine = overlay.machine { out.machine = machine }
        if let bootOrder = overlay.bootOrder { out.bootOrder = bootOrder }
        if let display = overlay.display { out.display = display }
        if let firmware = overlay.firmware {
            var merged = out.firmware ?? WorkloadFirmware(uefi: true, tpm: false)
            if let uefi = firmware.uefi { merged.uefi = uefi }
            if let tpm = firmware.tpm { merged.tpm = tpm }
            out.firmware = merged
        }
        return out
    }

    /// Validate both bags (shape) plus current-host capabilities.
    public static func validate(
        _ spec: WorkloadSpec,
        host: HostCapabilities = .current,
    ) throws {
        if let linux = spec.overrides?.linux, !linux.isEmpty {
            try validateOverlay(linux, path: "overrides.linux", platform: .linux)
            try validateMergedGuestType(spec, overlay: linux, path: "overrides.linux")
        }
        if let macos = spec.overrides?.macos, !macos.isEmpty {
            try validateOverlay(macos, path: "overrides.macos", platform: .macos)
            try validateMergedGuestType(spec, overlay: macos, path: "overrides.macos")
        }
        try validateAppliedCapabilities(spec, host: host)
    }

    private static func validateMergedGuestType(
        _ spec: WorkloadSpec,
        overlay: WorkloadSpecOverlay,
        path: String,
    ) throws {
        var trial = spec
        trial.spec = merge(spec.spec, with: overlay)
        do {
            _ = try WorkloadSpecProjector.resolveGuestType(trial)
        } catch let error as BarkVisorError {
            throw BarkVisorError.badRequest("\(path): \(error.localizedDescription)")
        }
    }

    public static func validateOverlay(
        _ overlay: WorkloadSpecOverlay,
        path: String,
        platform: HostPlatform,
    ) throws {
        if let cpu = overlay.resources?.cpu, cpu < 1 {
            throw BarkVisorError.badRequest("\(path).resources.cpu must be >= 1")
        }
        if let memoryMb = overlay.resources?.memoryMb, !(128 ... 1_048_576).contains(memoryMb) {
            throw BarkVisorError.badRequest("\(path).resources.memoryMb must be 128...1048576")
        }
        if let arch = overlay.arch, WorkloadSpecProjector.normalizeQEMUArch(arch) == nil {
            throw BarkVisorError.badRequest("\(path).arch is not a supported architecture")
        }
        if let guestType = overlay.guestType, !guestType.isEmpty {
            _ = try GuestProfiles.require(guestType)
        }
        if let resolution = overlay.display?.resolution {
            _ = try QEMUBuilder.validateResolution(resolution)
        }
        if overlay.hugepages != nil, platform != .linux {
            throw BarkVisorError.badRequest("\(path).hugepages is only valid on linux")
        }
        if let accelerator = overlay.accelerator {
            try validateAcceleratorShape(accelerator, path: "\(path).accelerator", platform: platform)
        }
    }

    public static func validateAppliedCapabilities(
        _ spec: WorkloadSpec,
        host: HostCapabilities = .current,
    ) throws {
        guard let overlay = hostOverlay(spec, host: host.platform) else { return }
        let path = "overrides.\(host.platform.rawValue)"
        if let accelerator = overlay.accelerator {
            try requireAccelerator(accelerator, path: "\(path).accelerator", host: host)
        }
        if overlay.hugepages == true, !host.hugepagesPresent {
            throw BarkVisorError.badRequest(
                "\(path).hugepages is not available: /dev/hugepages is missing",
            )
        }
        // PAS-48: overlay guestType/arch is what QEMU launches, not the portable vm.vmType.
        try requireCompatibleMergedGuestArch(spec, overlay: overlay, path: path)
    }

    /// Guest type QEMU will launch after applying the host overlay.
    ///
    /// `fromVM` stamps `spec.arch` from the portable `vm.vmType`. An overlay
    /// `guestType` is still the intended launch guest (QEMUBuilder resolves
    /// overrides independently of the persisted column).
    public static func launchGuestType(
        _ spec: WorkloadSpec,
        host: HostPlatform = .current,
    ) throws -> String {
        if let overlay = hostOverlay(spec, host: host),
           let guestType = overlay.guestType, !guestType.isEmpty {
            return try GuestProfiles.require(guestType).id
        }
        return try WorkloadSpecProjector.resolveGuestType(resolve(spec, host: host).spec)
    }

    public static func cpuModel(for accelerator: String) -> String {
        switch accelerator {
        case "hvf", "kvm":
            return "host"
        default:
            return "max"
        }
    }

    private static func requireCompatibleMergedGuestArch(
        _ spec: WorkloadSpec,
        overlay: WorkloadSpecOverlay,
        path: String,
    ) throws {
        // Overlay guestType/arch is the launch guest. Do not go through
        // resolveGuestType here: fromVM stamps portable spec.arch, which would
        // throw a mismatch and skip the PAS-48 host-arch block.
        if let guestType = overlay.guestType, !guestType.isEmpty {
            try requireCompatibleGuestArch(
                GuestProfiles.require(guestType).arch,
                field: "\(path).guestType",
            )
            return
        }
        if let arch = overlay.arch {
            try requireCompatibleGuestArch(arch, field: "\(path).arch")
            return
        }
        var trial = spec
        trial.spec = merge(spec.spec, with: overlay)
        let portableGuest = try WorkloadSpecProjector.resolveGuestType(spec)
        let mergedGuest = try WorkloadSpecProjector.resolveGuestType(trial)
        guard mergedGuest != portableGuest else { return }
        try requireCompatibleGuestArch(
            GuestProfiles.require(mergedGuest).arch,
            field: path,
        )
    }

    private static func requireCompatibleGuestArch(_ guestArch: String, field: String) throws {
        do {
            try PlatformCapabilities.requireCompatibleGuestArch(guestArch)
        } catch let error as BarkVisorError {
            throw BarkVisorError.badRequest("\(field): \(error.localizedDescription)")
        }
    }

    private static func validateAcceleratorShape(
        _ accelerator: String,
        path: String,
        platform: HostPlatform,
    ) throws {
        let allowed: Set<String> = switch platform {
        case .linux: ["kvm", "tcg"]
        case .macos: ["hvf", "tcg"]
        }
        guard allowed.contains(accelerator) else {
            let list = allowed.sorted().joined(separator: ", ")
            throw BarkVisorError.badRequest("\(path) must be one of: \(list)")
        }
    }

    private static func requireAccelerator(
        _ accelerator: String,
        path: String,
        host: HostCapabilities,
    ) throws {
        switch accelerator {
        case "kvm":
            guard host.kvmPresent else {
                throw BarkVisorError.badRequest("\(path) is not available: /dev/kvm is missing")
            }
        case "hvf":
            guard host.platform == .macos else {
                throw BarkVisorError.badRequest("\(path) is only available on macOS")
            }
        case "tcg":
            return
        default:
            throw BarkVisorError.badRequest("\(path) is not a supported accelerator")
        }
    }
}
