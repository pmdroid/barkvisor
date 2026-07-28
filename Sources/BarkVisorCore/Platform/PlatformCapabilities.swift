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
    public static var accelerator: String {
        #if os(macOS)
            "hvf"
        #else
            "kvm"
        #endif
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
