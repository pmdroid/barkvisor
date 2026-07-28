import Testing
@testable import BarkVisorCore

struct PlatformQEMUPathTests {
    // MARK: - Accelerator

    @Test func `PlatformCapabilities accelerator is host platform specific`() {
        #if os(macOS)
            #expect(PlatformCapabilities.accelerator == "hvf")
        #elseif os(Linux)
            #expect(PlatformCapabilities.accelerator == "kvm")
        #endif
    }

    @Test func `QEMUBuilder accelerator matches PlatformCapabilities`() {
        #expect(QEMUBuilder.accelerator == PlatformCapabilities.accelerator)
    }

    // MARK: - Firmware candidate tables

    @Test func `edk2ARM64Candidates is non-empty and includes AAVMF_CODE`() {
        let candidates = PlatformQEMU.edk2ARM64Candidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/AAVMF/AAVMF_CODE.fd"))
        #expect(candidates.contains { $0.contains("AAVMF_CODE") })
    }

    @Test func `edk2X86_64Candidates is non-empty and includes OVMF_CODE`() {
        let candidates = PlatformQEMU.edk2X86_64Candidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/OVMF/OVMF_CODE.fd"))
        #expect(candidates.contains { $0.contains("OVMF") })
    }

    @Test func `aavmfSecureBootCandidates is non-empty and includes secboot`() {
        let candidates = PlatformQEMU.aavmfSecureBootCandidates
        #expect(!candidates.isEmpty)
        #expect(candidates.contains("/usr/share/AAVMF/AAVMF_CODE.secboot.fd"))
    }

    // MARK: - Install hints

    @Test func `install hints are non-empty`() {
        #expect(!PlatformQEMU.qemuInstallHint.isEmpty)
        #expect(!PlatformQEMU.firmwareInstallHintARM64.isEmpty)
        #expect(!PlatformQEMU.firmwareInstallHintX86_64.isEmpty)
        #expect(!PlatformQEMU.aavmfSecureBootInstallHint.isEmpty)
        #expect(!PlatformQEMU.swtpmInstallHint.isEmpty)
    }

    @Test func `install hints mention platform package managers`() {
        #if os(macOS)
            #expect(PlatformQEMU.qemuInstallHint.contains("brew"))
            #expect(PlatformQEMU.firmwareInstallHintARM64.contains("brew"))
            #expect(PlatformQEMU.firmwareInstallHintX86_64.contains("brew"))
            #expect(PlatformQEMU.swtpmInstallHint.contains("brew"))
        #else
            #expect(PlatformQEMU.qemuInstallHint.contains("qemu-system"))
            #expect(PlatformQEMU.firmwareInstallHintARM64.contains("qemu-efi-aarch64"))
            #expect(PlatformQEMU.firmwareInstallHintX86_64.contains("ovmf"))
            #expect(PlatformQEMU.aavmfSecureBootInstallHint.contains("qemu-efi-aarch64"))
            #expect(PlatformQEMU.swtpmInstallHint.contains("swtpm"))
        #endif
    }
}
