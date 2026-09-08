import Testing
@testable import BarkVisorCore

struct PlatformQEMUPathTests {
    // MARK: - Accelerator

    @Test func `platformCapabilities accelerator is host platform specific`() {
        #if os(macOS)
            #expect(PlatformCapabilities.accelerator == "hvf")
            #expect(PlatformCapabilities.qemuCPUModel == "host")
        #elseif os(Linux)
            // KVM when /dev/kvm exists; TCG fallback (e.g. nested VM without nested virt).
            let accel = PlatformCapabilities.accelerator
            #expect(accel == "kvm" || accel == "tcg")
            #expect(PlatformCapabilities.qemuCPUModel == (accel == "kvm" ? "host" : "max"))
        #elseif os(Windows)
            let accel = PlatformCapabilities.accelerator
            #expect(accel == "whpx" || accel == "tcg")
            #expect(accel != "unknown")
        #endif
    }

    @Test func `qemuBuilder accelerator matches PlatformCapabilities`() {
        #expect(QEMUBuilder.accelerator == PlatformCapabilities.accelerator)
    }

    // MARK: - Firmware candidate tables

    @Test func `edk2ARM64Candidates is non-empty and includes AAVMF_CODE`() {
        let candidates = PlatformQEMU.edk2ARM64Candidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/AAVMF/AAVMF_CODE.fd"))
        #expect(candidates.contains { $0.contains("AAVMF_CODE") })
    }

    @Test func `edk2X86Candidates is non-empty and includes OVMF_CODE`() {
        let candidates = PlatformQEMU.edk2X86Candidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/OVMF/OVMF_CODE.fd"))
        #expect(candidates.contains { $0.contains("OVMF") })
    }

    @Test func `aavmfSecureBootCandidates is non-empty and includes secboot`() {
        let candidates = PlatformQEMU.aavmfSecureBootCandidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/AAVMF/AAVMF_CODE.secboot.fd"))
    }

    @Test func `ovmfSecureBootCandidates prefer secboot and 4M`() {
        let candidates = PlatformQEMU.ovmfSecureBootCandidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"))
        #expect(candidates.contains("/usr/share/OVMF/OVMF_CODE.secboot.fd"))
        #expect(candidates.first?.contains("secboot") == true)
        let vars = PlatformQEMU.ovmfSecureBootVarsCandidates
        #expect(vars.contains("/usr/share/OVMF/OVMF_VARS_4M.secboot.fd"))
        #expect(vars.contains("/usr/share/OVMF/OVMF_VARS.secboot.fd"))
    }

    @Test func `ovmf secure boot candidates include qemu windows share`() {
        let code = PlatformQEMU.ovmfSecureBootCandidates
        #expect(code.contains { $0.contains("Program Files") && $0.contains("OVMF_CODE_4M.secboot.fd") })
        #expect(code.contains { $0.contains("Program Files") && $0.contains("OVMF_CODE.secboot.fd") })
        #expect(code.contains { $0.contains("msys64") && $0.contains("edk2-x86_64-code.fd") })
        let vars = PlatformQEMU.ovmfSecureBootVarsCandidates
        #expect(vars.contains { $0.contains("Program Files") && $0.contains("OVMF_VARS_4M.fd") })
        #expect(vars.contains { $0.contains("Program Files") && $0.contains("edk2-x86_64-vars.fd") })
        let linuxVars = PlatformQEMU.edk2X86VarsCandidates
        #expect(linuxVars.contains { $0.contains("Program Files") && $0.contains("edk2-x86_64-vars.fd") })
    }

    // MARK: - Install hints

    @Test func `install hints are non-empty`() {
        #expect(!PlatformQEMU.qemuInstallHint.isEmpty)
        #expect(!PlatformQEMU.firmwareInstallHintARM64.isEmpty)
        #expect(!PlatformQEMU.firmwareInstallHintX86.isEmpty)
        #expect(!PlatformQEMU.aavmfSecureBootInstallHint.isEmpty)
        #expect(!PlatformQEMU.swtpmInstallHint.isEmpty)
    }

    @Test func `install hints mention platform package managers`() {
        #if os(macOS)
            #expect(PlatformQEMU.qemuInstallHint.contains("brew"))
            #expect(PlatformQEMU.firmwareInstallHintARM64.contains("brew"))
            #expect(PlatformQEMU.firmwareInstallHintX86.contains("brew"))
            #expect(PlatformQEMU.swtpmInstallHint.contains("brew"))
        #elseif os(Windows)
            #expect(PlatformQEMU.qemuInstallHint.contains("winget"))
            #expect(PlatformQEMU.firmwareInstallHintX86.contains("edk2-x86_64-code.fd"))
            #expect(PlatformQEMU.swtpmInstallHint.contains("swtpm"))
        #else
            #expect(PlatformQEMU.qemuInstallHint.contains("qemu-system"))
            #expect(PlatformQEMU.firmwareInstallHintARM64.contains("qemu-efi-aarch64"))
            #expect(PlatformQEMU.firmwareInstallHintX86.contains("ovmf"))
            #expect(PlatformQEMU.aavmfSecureBootInstallHint.contains("qemu-efi-aarch64"))
            #expect(PlatformQEMU.swtpmInstallHint.contains("swtpm"))
        #endif
    }
}
