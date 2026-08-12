import Testing
@testable import BarkVisorCore

struct GuestProfileTests {
    @Test func `stable persisted ids are present`() {
        let ids = Set(GuestProfiles.supportedIDs)
        #expect(ids == Set(["linux-arm64", "windows-arm64", "linux-amd64", "linux-x86_64"]))
    }

    @Test func `require known and unknown`() throws {
        let linux = try GuestProfiles.require("linux-arm64")
        #expect(linux.machine == "virt")
        #expect(linux.qemuBinaryName == "qemu-system-aarch64")
        #expect(linux.osFamily == "linux")
        #expect(linux.firmware == .edk2ARM64)

        let win = try GuestProfiles.require("windows-arm64")
        #expect(win.isWindows)
        #expect(win.defaultTPMEnabled)
        #expect(win.firmware == .aavmfSecureBoot)

        let x86 = try GuestProfiles.require("linux-amd64")
        #expect(x86.machine == "q35")
        #expect(x86.isX86)
        #expect(try GuestProfiles.require("linux-x86_64").machine == "q35")

        #expect(throws: BarkVisorError.self) {
            try GuestProfiles.require("solaris-sparc")
        }
    }

    @Test func `qemuBuilder uses guest profiles`() throws {
        #expect(QEMUBuilder.machineType(for: "linux-amd64") == "q35")
        #expect(QEMUBuilder.machineType(for: "linux-arm64") == "virt")
        #expect(try QEMUBuilder.binaryName(for: "windows-arm64") == "qemu-system-aarch64")
        #expect(try QEMUBuilder.binaryName(for: "linux-x86_64") == "qemu-system-x86_64")
    }

    @Test func `default linux id from image arch`() {
        #expect(GuestProfiles.defaultLinuxID(forImageArch: "arm64") == "linux-arm64")
        #expect(GuestProfiles.defaultLinuxID(forImageArch: "aarch64") == "linux-arm64")
        #expect(GuestProfiles.defaultLinuxID(forImageArch: "x86_64") == "linux-amd64")
        #expect(GuestProfiles.defaultLinuxID(forImageArch: "amd64") == "linux-amd64")
        #expect(GuestProfiles.defaultLinuxID(forImageArch: "x64") == "linux-amd64")
        #expect(GuestProfiles.defaultLinuxID(forImageArch: "X86_64") == "linux-amd64")
        #expect(GuestProfiles.defaultLinuxID(forImageArch: " AArch64 ") == "linux-arm64")
    }

    @Test func `default windows id only for arm64`() {
        #expect(GuestProfiles.defaultWindowsID(forImageArch: "arm64") == "windows-arm64")
        #expect(GuestProfiles.defaultWindowsID(forImageArch: "aarch64") == "windows-arm64")
        #expect(GuestProfiles.defaultWindowsID(forImageArch: "x86_64") == nil)
        #expect(GuestProfiles.defaultWindowsID(forImageArch: "amd64") == nil)
    }

    @Test func `profilesCompatible filters to host arch`() {
        let arm = GuestProfiles.profilesCompatible(withHostArch: "arm64")
        #expect(!arm.isEmpty)
        #expect(arm.allSatisfy { $0.arch == "arm64" })
        #expect(arm.contains { $0.id == "linux-arm64" })
        #expect(arm.contains { $0.id == "windows-arm64" })
        #expect(!arm.contains { $0.id == "linux-amd64" })

        let x86 = GuestProfiles.profilesCompatible(withHostArch: "x86_64")
        #expect(!x86.isEmpty)
        #expect(x86.allSatisfy { $0.arch == "x86_64" })
        #expect(x86.contains { $0.id == "linux-amd64" })
        #expect(!x86.contains { $0.id == "windows-arm64" })
    }
}
