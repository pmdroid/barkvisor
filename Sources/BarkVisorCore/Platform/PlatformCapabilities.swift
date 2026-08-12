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
    /// - macOS: socket_vmnet (requires managed daemon lifecycle below)
    /// - Linux: QEMU `-netdev bridge` against an existing host bridge (e.g. br0)
    public static var supportsBridgedNetworking: Bool {
        #if os(macOS) || os(Linux)
            true
        #else
            false
        #endif
    }

    /// Whether BarkVisor can install/start/stop a privileged bridge helper daemon.
    /// macOS only (socket_vmnet via XPC helper). Linux host bridges are OS-managed.
    public static var supportsManagedBridgeDaemon: Bool {
        #if os(macOS)
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

    /// In-app signed PKG update flow (macOS helper).
    public static var supportsInAppUpdate: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
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

    public enum Feature: String, Sendable {
        case bridgedNetworking
        case managedBridgeDaemon
        case usbPassthrough
        case inAppUpdate
    }

    /// Platform-correct remediation text for an unsupported feature.
    public static func unsupportedMessage(_ feature: Feature) -> String {
        switch feature {
        case .bridgedNetworking:
            #if os(Linux)
                return "Bridged networking requires a host bridge and qemu-bridge-helper "
                    + "(e.g. br0 + /etc/qemu/bridge.conf). Use NAT if bridging is unavailable."
            #elseif os(macOS)
                return "Bridged networking is not supported on this host. Use NAT networking."
            #else
                return "Bridged networking is not supported on this platform. Use NAT networking."
            #endif
        case .managedBridgeDaemon:
            #if os(Linux)
                return "Managed bridge daemon lifecycle is not supported on Linux. "
                    + "Create a host bridge with ip/netplan (e.g. br0), then attach VMs "
                    + "via a Bridged network record."
            #else
                return "Managed bridge daemon lifecycle is not supported on this platform."
            #endif
        case .usbPassthrough:
            #if os(Linux)
                return "USB passthrough is not available (install usbutils / check udev permissions)."
            #else
                return "USB passthrough is not supported on this platform."
            #endif
        case .inAppUpdate:
            #if os(Linux)
                return "In-app software updates are not supported on Linux yet. "
                    + "Update BarkVisor using your package manager or release artifacts."
            #else
                return "In-app software updates are not supported on this platform."
            #endif
        }
    }

    /// Throw `BarkVisorError.badRequest` when product bridged networking is unavailable.
    public static func requireBridgedNetworking() throws {
        guard supportsBridgedNetworking else {
            throw BarkVisorError.badRequest(unsupportedMessage(.bridgedNetworking))
        }
    }

    /// Throw when managed bridge daemon ops are unavailable.
    public static func requireManagedBridgeDaemon() throws {
        guard supportsManagedBridgeDaemon else {
            throw BarkVisorError.badRequest(unsupportedMessage(.managedBridgeDaemon))
        }
    }

    /// Throw when USB passthrough is unavailable.
    public static func requireUSBPassthrough() throws {
        guard supportsUSBPassthrough else {
            throw BarkVisorError.badRequest(unsupportedMessage(.usbPassthrough))
        }
    }

    /// Throw when in-app updates are unavailable.
    public static func requireInAppUpdate() throws {
        guard supportsInAppUpdate else {
            throw BarkVisorError.updateFailed(unsupportedMessage(.inAppUpdate))
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
    public static func normalizedArch(_ arch: String) -> String {
        switch arch {
        case "arm64", "aarch64": return "arm64"
        case "x86_64", "amd64": return "x86_64"
        default: return arch
        }
    }
}
