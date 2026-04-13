import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for Data Transfer Objects (DTOs) used in controllers.
struct DTOTests {
    // MARK: - VMResponse

    @Test func `vm response from VM`() {
        let vm = VM(
            id: "vm-1", name: "test-vm", vmType: "linux-arm64", state: "running",
            cpuCount: 4, memoryMb: 2_048, bootDiskId: "disk-1",
            isoId: nil, networkId: "net-1", cloudInitPath: nil, vncPort: nil,
            description: "A VM", bootOrder: "cd", displayResolution: "1920x1080",
            additionalDiskIds: "[\"disk-2\",\"disk-3\"]",
            uefi: true, tpmEnabled: false,
            macAddress: "52:54:00:12:34:56",
            sharedPaths: "[\"/Users/test/share\"]",
            portForwards: "[{\"protocol\":\"tcp\",\"hostPort\":2222,\"guestPort\":22}]",
            autoCreated: false, pendingChanges: true,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)

        #expect(response.id == "vm-1")
        #expect(response.name == "test-vm")
        #expect(response.vmType == "linux-arm64")
        #expect(response.state == "running")
        #expect(response.cpuCount == 4)
        #expect(response.memoryMB == 2_048)
        #expect(response.bootDiskId == "disk-1")
        #expect(response.networkId == "net-1")
        #expect(response.description == "A VM")
        #expect(response.uefi == true)
        #expect(response.tpmEnabled == false)
        #expect(response.macAddress == "52:54:00:12:34:56")
        #expect(response.pendingChanges == true)
        #expect(response.additionalDiskIds == ["disk-2", "disk-3"])
        #expect(response.sharedPaths == ["/Users/test/share"])
        #expect(response.portForwards?.count == 1)
        #expect(response.portForwards?.first?.guestPort == 22)
        #expect(response.portForwards?.first?.hostPort == 2_222)
    }

    @Test func `vm response nil optionals`() {
        let vm = VM(
            id: "vm-1", name: "minimal", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1",
            isoId: nil, networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)

        #expect(response.networkId == nil)
        #expect(response.description == nil)
        #expect(response.additionalDiskIds == nil)
        #expect(response.sharedPaths == nil)
        #expect(response.portForwards == nil)
        #expect(response.macAddress == nil)
        #expect(response.isoIds == nil)
        #expect(response.isoId == nil)
    }

    @Test func `vm response iso id backwards compat`() {
        let vm = VM(
            id: "vm-1", name: "iso-test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1",
            isoId: nil, isoIds: "[\"iso-1\",\"iso-2\"]",
            networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)
        #expect(response.isoId == "iso-1")
        #expect(response.isoIds == ["iso-1", "iso-2"])
    }

    @Test func `vm response legacy iso id`() {
        let vm = VM(
            id: "vm-1", name: "legacy-iso", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1",
            isoId: "legacy-iso-1", isoIds: nil,
            networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)
        #expect(response.isoId == "legacy-iso-1")
        #expect(response.isoIds == ["legacy-iso-1"])
    }

    // MARK: - VMResponse Encodable

    @Test func `vm response encodes to JSON`() throws {
        let vm = VM(
            id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-1",
            isoId: nil, networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: true, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)
        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(dict != nil)
        #expect(dict?["id"] as? String == "vm-1")
        #expect(dict?["memoryMB"] as? Int == 1_024)
        #expect(dict?["uefi"] as? Bool == true)
    }

    // MARK: - ImageResponse

    @Test func `image response from VM image`() {
        let image = VMImage(
            id: "img-1", name: "Ubuntu 24.04", imageType: "cloud-image", arch: "arm64",
            path: "/data/images/img-1.qcow2", sizeBytes: 1_073_741_824,
            status: "ready", error: nil,
            sourceUrl: "https://example.com/ubuntu.qcow2",
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = ImageResponse(from: image)

        #expect(response.id == "img-1")
        #expect(response.name == "Ubuntu 24.04")
        #expect(response.imageType == "cloud-image")
        #expect(response.arch == "arm64")
        #expect(response.status == "ready")
        #expect(response.sizeBytes == 1_073_741_824)
        #expect(response.sourceUrl == "https://example.com/ubuntu.qcow2")
        #expect(response.error == nil)
    }

    @Test func `image response with error`() {
        let image = VMImage(
            id: "img-2", name: "Failed", imageType: "iso", arch: "arm64",
            path: nil, sizeBytes: nil,
            status: "error", error: "Download failed",
            sourceUrl: "https://example.com/bad.iso",
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = ImageResponse(from: image)
        #expect(response.status == "error")
        #expect(response.error == "Download failed")
        #expect(response.sizeBytes == nil)
    }

    // MARK: - TemplateResponse

    @Test func `template response from VM template`() {
        let template = VMTemplate(
            id: "tpl-1", slug: "ubuntu-server",
            name: "Ubuntu Server", description: "A server template",
            category: "linux", icon: "ubuntu",
            imageSlug: "ubuntu-24.04",
            cpuCount: 2, memoryMB: 2_048, diskSizeGB: 20,
            portForwards: "[{\"protocol\":\"tcp\",\"hostPort\":2222,\"guestPort\":22}]",
            networkMode: "nat",
            inputs: "[{\"id\":\"hostname\",\"label\":\"Hostname\",\"type\":\"text\",\"default\":\"ubuntu\",\"required\":true}]",
            userDataTemplate: "#cloud-config\nhostname: {{hostname}}",
            isBuiltIn: true, repositoryId: nil,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = TemplateResponse(from: template)

        #expect(response.id == "tpl-1")
        #expect(response.slug == "ubuntu-server")
        #expect(response.name == "Ubuntu Server")
        #expect(response.category == "linux")
        #expect(response.cpuCount == 2)
        #expect(response.memoryMB == 2_048)
        #expect(response.diskSizeGB == 20)
        #expect(response.networkMode == "nat")
        #expect(response.isBuiltIn == true)
        #expect(response.portForwards?.count == 1)
        #expect(response.inputs.count == 1)
        #expect(response.inputs.first?.id == "hostname")
    }

    // MARK: - RepositoryResponse

    @Test func `repository response from image repository`() {
        let repo = ImageRepository(
            id: "repo-1", name: "Official", url: "https://example.com/repo.json",
            isBuiltIn: true, repoType: "images",
            lastSyncedAt: "2025-06-01T00:00:00Z", lastError: nil,
            syncStatus: "idle",
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-06-01T00:00:00Z",
        )

        let response = RepositoryResponse(from: repo)

        #expect(response.id == "repo-1")
        #expect(response.name == "Official")
        #expect(response.isBuiltIn == true)
        #expect(response.repoType == "images")
        #expect(response.syncStatus == "idle")
        #expect(response.lastSyncedAt != nil)
        #expect(response.lastError == nil)
    }

    // MARK: - RepositoryImageResponse

    @Test func `repository image response from model`() {
        let img = RepositoryImage(
            id: "ri-1", repositoryId: "repo-1", slug: "ubuntu-24.04",
            name: "Ubuntu 24.04", description: "LTS release",
            imageType: "cloud-image", arch: "arm64",
            version: "24.04", downloadUrl: "https://example.com/ubuntu.qcow2",
            sizeBytes: 1_073_741_824,
        )

        let response = RepositoryImageResponse(from: img)

        #expect(response.id == "ri-1")
        #expect(response.repositoryId == "repo-1")
        #expect(response.slug == "ubuntu-24.04")
        #expect(response.name == "Ubuntu 24.04")
        #expect(response.imageType == "cloud-image")
        #expect(response.downloadUrl == "https://example.com/ubuntu.qcow2")
    }

    // MARK: - GuestInfoResponse

    @Test func `guest info response from result`() {
        let result = GuestInfoResult(
            available: true, ipAddresses: ["10.0.0.5", "fd00::5"],
            macAddress: "52:54:00:12:34:56", ipSource: "guest-agent",
            hostname: "ubuntu-vm", osName: "Ubuntu", osVersion: "24.04",
            osId: "ubuntu", kernelVersion: "6.5.0", kernelRelease: "6.5.0-44-generic",
            machine: "aarch64", timezone: "UTC", timezoneOffset: 0,
            users: nil, filesystems: nil,
        )

        let response = GuestInfoResponse(from: result)

        #expect(response.available)
        #expect(response.ipAddresses == ["10.0.0.5", "fd00::5"])
        #expect(response.macAddress == "52:54:00:12:34:56")
        #expect(response.ipSource == "guest-agent")
        #expect(response.hostname == "ubuntu-vm")
        #expect(response.osName == "Ubuntu")
        #expect(response.osVersion == "24.04")
    }

    @Test func `guest info response unavailable`() {
        let result = GuestInfoResult(
            available: false, ipAddresses: [], macAddress: nil,
            ipSource: "none", hostname: nil, osName: nil, osVersion: nil,
            osId: nil, kernelVersion: nil, kernelRelease: nil, machine: nil,
            timezone: nil, timezoneOffset: nil, users: nil, filesystems: nil,
        )

        let response = GuestInfoResponse(from: result)

        #expect(!response.available)
        #expect(response.ipAddresses.isEmpty)
        #expect(response.hostname == nil)
    }
}
