import Foundation

#if os(macOS)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Static capability flags and remediation messages for the current host platform.
///
/// Prefer calling this type directly from services/controllers. PrivilegeService is only for
/// privileged operations (XPC / host bridge registration), not capability checks.
public enum PlatformCapabilities {
    /// Product capability: attach VMs to a host bridge / bridged network.
    /// - macOS: operator-managed Homebrew `socket_vmnet` (no BarkVisor helper)
    /// - Linux: QEMU `-netdev bridge` against an existing host bridge (e.g. br0)
    public static var supportsBridgedNetworking: Bool {
        #if os(macOS) || os(Linux)
            true
        #else
            false
        #endif
    }

    /// Whether BarkVisor can install/start/stop a privileged bridge helper daemon.
    /// Always false: macOS uses Homebrew `socket_vmnet`; Linux host bridges are OS-managed.
    public static var supportsManagedBridgeDaemon: Bool {
        false
    }

    /// Linux Manage Bridges shows host-bridge setup guidance (no mutation).
    public static var supportsHostBridgeManagement: Bool {
        #if os(Linux)
            true
        #else
            false
        #endif
    }

    /// USB device passthrough into guests (`usb-host` device).
    /// - macOS: ioreg enumeration
    /// - Linux: `lsusb` enumeration (permissions via udev / plugdev)
    public static var supportsUSBPassthrough: Bool {
        #if os(macOS) || os(Linux)
            true
        #else
            false
        #endif
    }

    /// In-app signed PKG update flow. Always false: the privileged helper is gone;
    /// upgrade with Homebrew / the distro package.
    public static var supportsInAppUpdate: Bool {
        false
    }

    /// QEMU accelerator name for this host.
    /// Linux uses KVM when `/dev/kvm` is present; otherwise falls back to TCG
    /// (common in nested VMs such as OrbStack without nested virt).
    public static var accelerator: String {
        #if os(macOS)
            return "hvf"
        #elseif os(Linux)
            if FileManager.default.fileExists(atPath: "/dev/kvm") {
                return "kvm"
            }
            return "tcg"
        #else
            return "tcg"
        #endif
    }

    /// QEMU `-cpu` model matching the accelerator.
    /// `host` requires KVM/HVF; TCG needs a software model (`max`).
    public static var qemuCPUModel: String {
        switch accelerator {
        case "hvf", "kvm":
            return "host"
        default:
            return "max"
        }
    }

    /// Host CPU architecture for API/UI (`arm64` / `x86_64`).
    /// Single implementation: runtime `uname` (matches process machine).
    public static var hostArch: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let normalized = normalizedArch(machine)
        return normalized.isEmpty ? "x86_64" : normalized
    }

    /// Default QEMU guest architecture for this host (`aarch64` / `x86_64`).
    public static var defaultGuestArch: String {
        hostArch == "arm64" ? "aarch64" : "x86_64"
    }

    // MARK: - Unsupported feature messages

    public enum Feature: String, Sendable, Equatable, CaseIterable {
        case bridgedNetworking
        case managedBridgeDaemon
        case usbPassthrough
        case inAppUpdate
        case gpuPassthrough

        /// Snake_case API error `code` (ErrorMiddleware envelope).
        public var errorCode: String {
            switch self {
            case .bridgedNetworking: return "bridged_networking"
            case .managedBridgeDaemon: return "managed_bridge_daemon"
            case .usbPassthrough: return "usb_passthrough"
            case .inAppUpdate: return "in_app_update"
            case .gpuPassthrough: return "gpu_passthrough"
            }
        }
    }

    /// Platform-correct remediation text for an unsupported feature.
    public static func unsupportedMessage(_ feature: Feature) -> String {
        CapabilityDetailBuilder.remediation(for: feature, os: PlatformHost.platformName)
    }

    /// Throw `BarkVisorError.unsupportedFeature` when product bridged networking is unavailable.
    ///
    /// Matches `/api/system/capabilities` (inventory), not the compile-time platform flag.
    /// On Linux that means qemu-bridge-helper must be present.
    public static func requireBridgedNetworking() throws {
        let supported = HostInventoryService.bridgedNetworkingSupported(
            platformSupports: supportsBridgedNetworking,
            qemuBridgeHelper: HostInventoryService.qemuBridgeHelperPresent(),
            os: PlatformHost.platformName,
        )
        guard supported else {
            throw BarkVisorError.unsupportedFeature(.bridgedNetworking)
        }
    }

    /// Throw when managed bridge daemon ops are unavailable.
    public static func requireManagedBridgeDaemon() throws {
        guard supportsManagedBridgeDaemon else {
            throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
        }
    }

    /// Throw when USB passthrough is unavailable.
    public static func requireUSBPassthrough() throws {
        guard supportsUSBPassthrough else {
            throw BarkVisorError.unsupportedFeature(.usbPassthrough)
        }
    }

    /// Throw when IOMMU/vfio/KVM GPU passthrough is not ready (PAS-275).
    public static func requireGPUPassthrough() throws {
        let facts = VFIOProbe.live()
        guard VFIOProbe.gpuPassthroughSupported(os: PlatformHost.platformName, facts: facts) else {
            throw BarkVisorError.unsupportedFeature(.gpuPassthrough)
        }
    }

    /// Whether a guest/workload arch label is compatible with this host.
    ///
    /// Labels are normalized the same way as ``hostArch`` (`arm64` / `x86_64`).
    /// Wave 0 policy: **block** cross-arch by default (no force flag yet), on both
    /// HVF/KVM (`-cpu host` fails badly) and TCG hosts. Emulation may work on TCG
    /// with a foreign `qemu-system-*` binary, but that path is intentionally
    /// unsupported until an advanced override exists.
    public static func isCompatibleGuestArch(_ guestArch: String) -> Bool {
        normalizedArch(guestArch) == hostArch
    }

    /// Throw `BarkVisorError.badRequest` when guest arch ≠ host arch.
    public static func requireCompatibleGuestArch(_ guestArch: String) throws {
        let guest = normalizedArch(guestArch)
        let host = hostArch
        guard guest == host else {
            throw BarkVisorError.badRequest(
                "VM architecture (\(guest)) is not compatible with this host (\(host)). "
                    + "Cross-architecture VMs are not supported.",
            )
        }
    }

    /// Normalize common arch aliases to API labels (`arm64` / `x86_64`).
    /// Matches frontend `normalizeImageArch` (lowercase, trim, `x64` → `x86_64`).
    public static func normalizedArch(_ arch: String) -> String {
        switch arch.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "arm64", "aarch64": return "arm64"
        case "x86_64", "amd64", "x64": return "x86_64"
        default: return arch
        }
    }
}
