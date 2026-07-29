import Foundation

/// Static capability flags for the current host platform.
public enum PlatformCapabilities {
    /// Bridged networking via privileged helper / socket_vmnet (macOS today).
    public static var supportsBridgedNetworking: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    /// USB device passthrough into guests.
    public static var supportsUSBPassthrough: Bool {
        #if os(macOS)
            true
        #else
            // Available via vfio on Linux in a later PR.
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

    /// Default guest architecture matching the host CPU.
    public static var defaultGuestArch: String {
        #if arch(arm64)
            "aarch64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "x86_64"
        #endif
    }
}
