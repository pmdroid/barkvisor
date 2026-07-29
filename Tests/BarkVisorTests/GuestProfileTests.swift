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
    }
}
