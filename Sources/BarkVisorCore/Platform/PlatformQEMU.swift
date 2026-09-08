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
    public static var windowsQEMUShareDirs: [String] {
        [
            "C:\\Program Files\\qemu\\share",
            "C:\\Program Files\\qemu\\share\\qemu",
            "C:\\msys64\\ucrt64\\share\\qemu",
        ]
    }

    public static var edk2ARM64Candidates: [String] {
        [
            "/usr/share/AAVMF/AAVMF_CODE.fd",
            "/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
            "/usr/share/edk2/aarch64/QEMU_EFI.fd",
            "/usr/share/edk2-arm/QEMU_EFI.fd",
            // Arch: edk2-armvirt
            "/usr/share/edk2/arm/QEMU_EFI.fd",
            "/usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd",
            // Alpine
            "/usr/share/OVMF/QEMU_EFI.fd",
        ] + windowsQEMUShareDirs.map { "\($0)\\edk2-aarch64-code.fd" }
    }

    /// System paths for x86_64 UEFI firmware (OVMF / EDK2).
    /// Prefer 4M images first — they pair with `OVMF_VARS_4M.fd` on modern Ubuntu.
    /// Checked after `BundleResolver.qemuResource` for edk2/OVMF names.
    public static var edk2X86Candidates: [String] {
        [
            "/usr/share/OVMF/OVMF_CODE_4M.fd",
            "/usr/share/OVMF/OVMF_CODE.fd",
            "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
            "/usr/share/OVMF/OVMF_CODE.secboot.fd",
            "/usr/share/edk2/ovmf/OVMF_CODE.fd",
            "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
            "/usr/share/edk2/x64/OVMF_CODE.fd",
            "/usr/share/edk2/x64/OVMF_CODE.4m.fd",
            // Arch: edk2-ovmf
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd",
            "/usr/share/ovmf/x64/OVMF_CODE.fd",
            "/usr/share/qemu/OVMF.fd",
            "/usr/share/qemu/edk2-x86_64-code.fd",
        ] + windowsQEMUShareDirs.map { "\($0)\\edk2-x86_64-code.fd" }
    }

    /// NVRAM var store templates matching common CODE images (must copy, not zero-fill).
    public static var edk2X86VarsCandidates: [String] {
        [
            "/usr/share/OVMF/OVMF_VARS_4M.fd",
            "/usr/share/OVMF/OVMF_VARS.fd",
            "/usr/share/edk2/ovmf/OVMF_VARS.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd",
            "/usr/share/edk2/x64/OVMF_VARS.fd",
            "/usr/share/edk2/x64/OVMF_VARS.4m.fd",
            "/usr/share/ovmf/x64/OVMF_VARS.fd",
            "/usr/share/qemu/OVMF_VARS.fd",
            "/usr/share/qemu/edk2-x86_64-vars.fd",
            // Some QEMU packages (Fedora-style firmware.json layouts) ship
            // x86_64 CODE with the shared i386 vars template.
            "/usr/share/qemu/edk2-i386-vars.fd",
        ]
    }

    /// AAVMF / ARM64 NVRAM templates when available.
    public static var aavmfVarsCandidates: [String] {
        [
            "/usr/share/AAVMF/AAVMF_VARS.fd",
            "/usr/share/AAVMF/AAVMF_VARS.ms.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_VARS.fd",
            "/usr/share/edk2-armvirt/aarch64/QEMU_VARS.fd",
            "/usr/share/edk2/arm/QEMU_VARS.fd",
        ]
    }

    /// System paths for AAVMF secure-boot firmware (Windows ARM64 guests).
    /// Checked after bundled `Config.qemuShareDir` / BundleResolver lookup.
    public static var aavmfSecureBootCandidates: [String] {
        [
            "/usr/share/AAVMF/AAVMF_CODE.secboot.fd",
            "/usr/share/AAVMF/AAVMF_CODE.ms.fd",
            "/usr/share/AAVMF/AAVMF_CODE.fd",
            "/usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd",
        ]
    }

    /// System paths for x86_64 OVMF secure-boot firmware (Windows amd64 guests).
    /// Prefer `OVMF_CODE.secboot` / 4M, then fall back to non-secboot OVMF.
    public static var ovmfSecureBootCandidates: [String] {
        [
            "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
            "/usr/share/OVMF/OVMF_CODE.secboot.fd",
            "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd",
            "/usr/share/edk2/x64/OVMF_CODE.secboot.fd",
            "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.4m.fd",
            "/usr/share/edk2/x64/OVMF_CODE.4m.fd",
            "/usr/share/OVMF/OVMF_CODE_4M.fd",
            "/usr/share/OVMF/OVMF_CODE.fd",
            "/usr/share/edk2/ovmf/OVMF_CODE.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
            "/usr/share/edk2/x64/OVMF_CODE.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd",
            "/usr/share/ovmf/x64/OVMF_CODE.fd",
            "/usr/share/qemu/OVMF.fd",
            "/usr/share/qemu/edk2-x86_64-code.fd",
        ]
    }

    /// NVRAM templates matching OVMF secure-boot CODE (4M / secboot first).
    public static var ovmfSecureBootVarsCandidates: [String] {
        [
            "/usr/share/OVMF/OVMF_VARS_4M.secboot.fd",
            "/usr/share/OVMF/OVMF_VARS.secboot.fd",
            "/usr/share/OVMF/OVMF_VARS_4M.ms.fd",
            "/usr/share/OVMF/OVMF_VARS.ms.fd",
            "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_VARS.secboot.fd",
            "/usr/share/OVMF/OVMF_VARS_4M.fd",
            "/usr/share/OVMF/OVMF_VARS.fd",
            "/usr/share/edk2/ovmf/OVMF_VARS.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd",
            "/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd",
            "/usr/share/edk2/x64/OVMF_VARS.fd",
            "/usr/share/edk2/x64/OVMF_VARS.4m.fd",
            "/usr/share/ovmf/x64/OVMF_VARS.fd",
            "/usr/share/qemu/OVMF_VARS.fd",
            "/usr/share/qemu/edk2-x86_64-vars.fd",
            "/usr/share/qemu/edk2-i386-vars.fd",
        ]
    }

    // MARK: - Install hints

    /// How to install QEMU system emulators on this platform.
    public static var qemuInstallHint: String {
        qemuInstallHint(os: PlatformHost.platformName)
    }

    public static func qemuInstallHint(os: String) -> String {
        if os.caseInsensitiveCompare("Windows") == .orderedSame {
            return "winget install qemu  |  MSYS2: pacman -S mingw-w64-ucrt-x86_64-qemu  |  installer: C:\\Program Files\\qemu"
        }
        if os.caseInsensitiveCompare("macOS") == .orderedSame {
            return "brew install qemu"
        }
        return "install QEMU: apt install qemu-system  |  pacman -S qemu-base  |  dnf install qemu-kvm|qemu-system-x86  |  apk add qemu-system-x86_64"
    }

    /// How to install the QEMU hardware modules Arch/SteamOS split out of qemu-base.
    public static var qemuDeviceInstallHint: String {
        qemuDeviceInstallHint(os: PlatformHost.platformName)
    }

    public static func qemuDeviceInstallHint(os: String) -> String {
        if os.caseInsensitiveCompare("Windows") == .orderedSame {
            return "reinstall QEMU (winget install qemu or C:\\Program Files\\qemu) so device modules are present"
        }
        if os.caseInsensitiveCompare("macOS") == .orderedSame {
            return "reinstall qemu: brew install qemu"
        }
        return "QEMU is missing device modules. "
            + "Arch/SteamOS: pacman -S qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-pci (split out of qemu-base)  "
            + "|  Debian/Ubuntu: apt install qemu-system-x86 (full package, not qemu-system-misc)  |  Fedora: dnf install qemu-kvm"
    }

    /// How to install ARM64 UEFI firmware on this platform.
    public static var firmwareInstallHintARM64: String {
        #if os(macOS)
            "brew install qemu"
        #elseif os(Windows)
            "install QEMU so share\\edk2-aarch64-code.fd is next to qemu-system-aarch64.exe (C:\\Program Files\\qemu\\share)"
        #else
            "apt: qemu-efi-aarch64  |  pacman: edk2-armvirt  |  apk: ovmf"
        #endif
    }

    /// How to install x86_64 UEFI firmware on this platform.
    public static var firmwareInstallHintX86: String {
        firmwareInstallHintX86(os: PlatformHost.platformName)
    }

    public static func firmwareInstallHintX86(os: String) -> String {
        if os.caseInsensitiveCompare("Windows") == .orderedSame {
            return "install QEMU so share\\edk2-x86_64-code.fd is next to qemu-system-x86_64.exe (C:\\Program Files\\qemu\\share)"
        }
        if os.caseInsensitiveCompare("macOS") == .orderedSame {
            return "brew install qemu"
        }
        return "apt: ovmf  |  pacman: edk2-ovmf  |  dnf: edk2-ovmf  |  apk: ovmf"
    }

    /// How to obtain AAVMF secure-boot firmware on this platform.
    public static var aavmfSecureBootInstallHint: String {
        #if os(macOS)
            "brew install qemu  (AAVMF/edk2 firmware ships in the qemu bottle)"
        #elseif os(Windows)
            "install QEMU (winget or C:\\Program Files\\qemu) for AAVMF/edk2 firmware in the share directory"
        #else
            "apt: qemu-efi-aarch64  |  pacman: edk2-armvirt"
        #endif
    }

    /// How to install swtpm (TPM 2.0 emulation) on this platform.
    public static var swtpmInstallHint: String {
        #if os(macOS)
            "brew install swtpm"
        #elseif os(Windows)
            "install swtpm.exe (MSYS2: pacman -S mingw-w64-ucrt-x86_64-swtpm) and keep it on PATH"
        #else
            "apt/pacman/apk/dnf: swtpm"
        #endif
    }

    /// How to install qemu-img (provisioning disks from images).
    public static var qemuImgInstallHint: String {
        qemuImgInstallHint(os: PlatformHost.platformName)
    }

    public static func qemuImgInstallHint(os: String) -> String {
        if os.caseInsensitiveCompare("Windows") == .orderedSame {
            return "qemu-img.exe is required to clone and resize image disks. winget install qemu  |  C:\\Program Files\\qemu\\qemu-img.exe"
        }
        if os.caseInsensitiveCompare("macOS") == .orderedSame {
            return "brew install qemu"
        }
        return "qemu-img is required to clone and resize image disks. apt: qemu-utils  |  pacman: qemu-base  |  dnf: qemu-img  |  apk: qemu-img"
    }

    /// How to install an mkisofs-compatible ISO tool for cloud-init.
    public static var isoToolInstallHint: String {
        isoToolInstallHint(os: PlatformHost.platformName)
    }

    public static func isoToolInstallHint(os: String) -> String {
        if os.caseInsensitiveCompare("Windows") == .orderedSame {
            return "install xorriso or mkisofs (MSYS2: pacman -S mingw-w64-ucrt-x86_64-libisoburn) and keep it on PATH"
        }
        if os.caseInsensitiveCompare("macOS") == .orderedSame {
            return "Reinstall BarkVisor (bundled mkisofs) or: brew install cdrtools"
        }
        return "apt: genisoimage  |  pacman: cdrtools  |  dnf: genisoimage|xorriso  |  apk: xorriso"
    }
}
