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
            minMemoryMB: nil,
            requiredFeatures: nil,
            compatible: true,
            catalogImages: nil,
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
        #expect(inputs["ssh_keys"] == "ssh-ed25519 AAA laptop")
    }

    @Test func seedTemplateInputsUsesDefaults() {
        let template = VMTemplateRecord(
            id: "t1",
            slug: "rocky-cloud",
            name: "Rocky Linux 9",
            description: nil,
            category: "linux",
            icon: "linux",
            imageSlug: "rocky-9-arm64",
            cpuCount: 2,
            memoryMB: 2048,
            diskSizeGB: 20,
            networkMode: "nat",
            inputs: [
                TemplateInputRecord(id: "username", label: "Username", required: true, default: "rocky", minLength: nil),
                TemplateInputRecord(id: "ssh_keys", label: "SSH", required: true, default: nil, minLength: nil),
            ],
            userDataTemplate: "",
            architectures: ["arm64"],
            minMemoryMB: nil,
            requiredFeatures: nil,
            compatible: true,
            catalogImages: nil,
        )
        let seeded = CreateVMWizard.seedTemplateInputs(template)
        #expect(seeded["username"] == "rocky")
        #expect(seeded["ssh_keys"] == nil)
        #expect(CreateVMWizard.templateInputsComplete(template, values: seeded))
    }

    @Test func sshKeyCloudInitComment() {
        let key = SSHKeyRecord(
            id: "k1",
            name: "laptop",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5",
            fingerprint: "fp",
            keyType: "ed25519",
            isDefault: true,
            createdAt: "now",
        )
        #expect(key.cloudInitAuthorizedKey.hasSuffix(" laptop"))
    }

    @Test func sshKeyLabelMarksDefaultOnlyAmongMultipleKeys() {
        func key(_ id: String, name: String, isDefault: Bool) -> SSHKeyRecord {
            SSHKeyRecord(
                id: id,
                name: name,
                publicKey: "ssh-ed25519 AAA",
                fingerprint: "fp",
                keyType: "ed25519",
                isDefault: isDefault,
                createdAt: "now",
            )
        }
        let lone = key("k1", name: "Github", isDefault: true)
        #expect(CreateVMWizard.sshKeyLabel(lone, keyCount: 1) == "Github")
        let primary = key("k1", name: "Github", isDefault: true)
        let other = key("k2", name: "laptop", isDefault: false)
        #expect(CreateVMWizard.sshKeyLabel(primary, keyCount: 2) == "Github (default)")
        #expect(CreateVMWizard.sshKeyLabel(other, keyCount: 2) == "laptop")
    }

    @Test func applyingCreatedKeySelectsTheNewKeyWithoutDroppingExisting() {
        func key(_ id: String, name: String) -> SSHKeyRecord {
            SSHKeyRecord(
                id: id,
                name: name,
                publicKey: "ssh-ed25519 AAA",
                fingerprint: "fp",
                keyType: "ed25519",
                isDefault: false,
                createdAt: "now",
            )
        }
        let existing = key("k1", name: "Github")
        let created = key("k-new", name: "ci-server")
        let next = CreateVMWizard.applyingCreatedKey(created, to: [existing])
        #expect(next.map(\.id) == ["k-new", "k1"])
        #expect(CreateVMWizard.applyingCreatedKey(created, to: next).map(\.id) == ["k-new", "k1"])
    }

    @Test func createWizardAddsSSHKeyInPlace() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/CreateVMWizardView.swift"),
            encoding: .utf8,
        )
        #expect(source.contains("Add another key"))
        #expect(source.contains("Add an SSH key"))
        #expect(source.contains("createSSHKey"))
        #expect(source.contains("applyingCreatedKey"))
        #expect(source.contains("This VM needs an SSH key for first login"))
        #expect(!source.contains("settings?tab=sshkeys"))
        #expect(!source.contains("target=\"_blank\""))
        let client = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Services/APIClient.swift"),
            encoding: .utf8,
        )
        #expect(client.contains("func createSSHKey(name: String, publicKey: String)"))
        #expect(client.contains("\"/api/ssh-keys\""))
    }

    @Test func resolveTemplateBySlugOnMember() {
        let home = VMTemplateRecord(
            id: "self-id",
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
            inputs: nil,
            userDataTemplate: "",
            architectures: ["x86_64"],
            minMemoryMB: nil,
            requiredFeatures: nil,
            compatible: true,
            catalogImages: nil,
        )
        let member = VMTemplateRecord(
            id: "member-id",
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
            inputs: nil,
            userDataTemplate: "",
            architectures: ["x86_64"],
            minMemoryMB: nil,
            requiredFeatures: nil,
            compatible: true,
            catalogImages: nil,
        )
        let resolved = CreateVMWizard.resolveTemplate(home, on: [member])
        #expect(resolved.id == "member-id")
    }

    @Test func buildDeployRecipeFromCatalogImages() {
        let template = VMTemplateRecord(
            id: "tpl",
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
            inputs: [],
            userDataTemplate: "#cloud-config",
            architectures: ["x86_64"],
            minMemoryMB: nil,
            requiredFeatures: nil,
            compatible: true,
            catalogImages: [
                TemplateCatalogImageRecord(
                    slug: "ubuntu-noble",
                    name: "Ubuntu",
                    imageType: "cloud",
                    arch: "x86_64",
                    downloadUrl: "https://example.test/ubuntu.img",
                    sha256: "abc",
                    sha512: nil,
                ),
            ],
        )
        let recipe = CreateVMWizard.buildDeployRecipe(template: template, hostArch: "amd64")
        #expect(recipe?.image.downloadUrl == "https://example.test/ubuntu.img")
        #expect(recipe?.slug == "ubuntu")
    }

    @Test func deployRecipeInputsIncludeType() throws {
        let template = VMTemplateRecord(
            id: "t1",
            slug: "rocky-cloud",
            name: "Rocky Linux 9",
            description: nil,
            category: "linux",
            icon: "linux",
            imageSlug: "rocky-9-arm64",
            cpuCount: 2,
            memoryMB: 2048,
            diskSizeGB: 20,
            networkMode: "nat",
            inputs: [
                TemplateInputRecord(id: "username", label: "Username", type: "text", required: true, default: "rocky", minLength: nil),
                TemplateInputRecord(id: "ssh_keys", label: "SSH", type: "textarea", required: true, default: nil, minLength: nil),
            ],
            userDataTemplate: "#cloud-config",
            architectures: ["arm64"],
            minMemoryMB: nil,
            requiredFeatures: nil,
            compatible: true,
            catalogImages: [
                TemplateCatalogImageRecord(
                    slug: "rocky-9-arm64",
                    name: "Rocky",
                    imageType: "cloud",
                    arch: "arm64",
                    downloadUrl: "https://example.test/rocky.img",
                    sha256: "abc",
                    sha512: nil,
                ),
            ],
        )
        guard let recipe = CreateVMWizard.buildDeployRecipe(template: template, hostArch: "arm64") else {
            Issue.record("Expected deploy recipe")
            return
        }
        let data = try JSONEncoder().encode(recipe)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"type\":\"text\""))
        #expect(json.contains("\"type\":\"textarea\""))
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
