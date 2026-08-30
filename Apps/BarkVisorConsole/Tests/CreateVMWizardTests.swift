import Foundation
import Testing

@testable import BarkVisorConsole

struct CreateVMWizardTests {
    @Test func sizePresetsClampToHost() {
        let presets = CreateVMWizard.clampedPresets(hostCPU: 4, hostMemoryMB: 8_192)
        #expect(presets.allSatisfy { $0.cpu <= 2 })
        #expect(presets.allSatisfy { $0.memoryMB <= 4_096 })
    }

    @Test func templateSSHDeployInputs() {
        let template = VMTemplateRecord(
            id: "t1",
            slug: "ubuntu",
            name: "Ubuntu",
            description: nil,
            category: "linux",
            icon: "linux",
            imageSlug: "ubuntu",
            cpuCount: 2,
            memoryMB: 4096,
            diskSizeGB: 32,
            networkMode: "nat",
            inputs: [
                TemplateInputRecord(id: "ssh_keys", label: "SSH", required: true, default: nil, minLength: nil),
                TemplateInputRecord(id: "hostname", label: "Host", required: true, default: nil, minLength: 3),
            ],
            userDataTemplate: "",
            architectures: ["x86_64"],
            compatible: true,
        )
        let key = SSHKeyRecord(
            id: "k1",
            name: "laptop",
            publicKey: "ssh-ed25519 AAA",
            fingerprint: "fp",
            keyType: "ed25519",
            isDefault: true,
            createdAt: "now",
        )
        let inputs = CreateVMWizard.deployInputs(
            template: template,
            values: ["hostname": "dev"],
            sshKey: key,
        )
        #expect(inputs["hostname"] == "dev")
        #expect(inputs["ssh_keys"] == "ssh-ed25519 AAA")
    }

    @Test func wizardBodyIncludesSSHForCloudImage() throws {
        let image = LibraryImage(
            id: "img1",
            name: "Ubuntu 24.04",
            imageType: "cloud",
            arch: "x86_64",
            status: "ready",
            sizeBytes: nil,
            sourceUrl: nil,
            error: nil,
            createdAt: "now",
            updatedAt: "now",
        )
        let body = try CreateWorkload.wizardBody(
            name: "dev",
            image: image,
            hostCPUCount: 8,
            preset: CreateVMWizard.presets[0],
            diskSource: .new,
            diskSizeGB: 32,
            existingDiskID: "",
            sshPublicKey: "ssh-ed25519 AAA",
        )
        #expect(body.cloudInit?.sshAuthorizedKeys == ["ssh-ed25519 AAA"])
    }
}
