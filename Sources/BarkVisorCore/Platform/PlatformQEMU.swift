import Foundation

/// QEMU firmware search paths and install hints for the current host platform.
///
/// Binary resolution still goes through `BundleResolver` first (installed layout,
/// Homebrew share, FHS qemu share). These tables cover distro-specific firmware
/// locations that live outside the QEMU share directory.
public enum PlatformQEMU {
    // MARK: - Firmware candidate paths

    /// System paths for aarch64/ARM64 UEFI firmware (AAVMF / EDK2).
    /// Checked after `BundleResolver.qemuResource("edk2-aarch64-code.fd")`.
    public static var edk2ARM64Candidates: [String] {
        [
            "/usr/share/AAVMF/AAVMF_CODE.fd",
            "/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
            "/usr/share/edk2/aarch64/QEMU_EFI.fd",
            "/usr/share/edk2-arm/QEMU_EFI.fd",
        ]
    }

    /// System paths for x86_64 UEFI firmware (OVMF / EDK2).
    /// Prefer 4M images first — they pair with `OVMF_VARS_4M.fd` on modern Ubuntu.
    /// Checked after `BundleResolver.qemuResource` for edk2/OVMF names.
    public static var edk2X86Candidates: [String] {
        [
            "/usr/share/OVMF/OVMF_CODE_4M.fd",
            "/usr/share/OVMF/OVMF_CODE.fd",
            "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
            "/usr/share/edk2/ovmf/OVMF_CODE.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
            "/usr/share/qemu/OVMF.fd",
        ]
    }

    /// NVRAM var store templates matching common CODE images (must copy, not zero-fill).
    public static var edk2X86VarsCandidates: [String] {
        [
            "/usr/share/OVMF/OVMF_VARS_4M.fd",
            "/usr/share/OVMF/OVMF_VARS.fd",
            "/usr/share/edk2/ovmf/OVMF_VARS.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd",
            "/usr/share/qemu/OVMF_VARS.fd",
        ]
    }

    /// AAVMF / ARM64 NVRAM templates when available.
    public static var aavmfVarsCandidates: [String] {
        [
            "/usr/share/AAVMF/AAVMF_VARS.fd",
            "/usr/share/AAVMF/AAVMF_VARS.ms.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_VARS.fd",
        ]
    }

    /// System paths for AAVMF secure-boot firmware (Windows ARM64 guests).
    /// Checked after bundled `Config.qemuShareDir` / BundleResolver lookup.
    public static var aavmfSecureBootCandidates: [String] {
        [
            "/usr/share/AAVMF/AAVMF_CODE.secboot.fd",
            "/usr/share/AAVMF/AAVMF_CODE.ms.fd",
            "/usr/share/AAVMF/AAVMF_CODE.fd",
        ]
    }

    // MARK: - Install hints

    /// How to install QEMU system emulators on this platform.
    public static var qemuInstallHint: String {
        #if os(macOS)
            "brew install qemu"
        #else
            "install qemu-system (e.g. apt install qemu-system)"
        #endif
    }

    /// How to install ARM64 UEFI firmware on this platform.
    public static var firmwareInstallHintARM64: String {
        #if os(macOS)
            "brew install qemu"
        #else
            "apt install qemu-efi-aarch64 qemu-system-arm"
        #endif
    }

    /// How to install x86_64 UEFI firmware on this platform.
    public static var firmwareInstallHintX86: String {
        #if os(macOS)
            "brew install qemu"
        #else
            "apt install ovmf qemu-system-x86"
        #endif
    }

    /// How to obtain AAVMF secure-boot firmware on this platform.
    public static var aavmfSecureBootInstallHint: String {
        #if os(macOS)
            "Reinstall BarkVisor or run scripts/build-release.sh to bundle firmware."
        #else
            "Install via: apt install qemu-efi-aarch64"
        #endif
    }

    /// How to install swtpm (TPM 2.0 emulation) on this platform.
    public static var swtpmInstallHint: String {
        #if os(macOS)
            "brew install swtpm"
        #else
            "apt install swtpm"
        #endif
    }
}
