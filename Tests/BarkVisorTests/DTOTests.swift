import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for Data Transfer Objects (DTOs) used in controllers.
/// Verifies JSON round-trip encoding and initialization from model objects.
final class DTOTests: XCTestCase {
    // MARK: - VMResponse

    func testVMResponseFromVM() {
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
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)

        XCTAssertEqual(response.id, "vm-1")
        XCTAssertEqual(response.name, "test-vm")
        XCTAssertEqual(response.vmType, "linux-arm64")
        XCTAssertEqual(response.state, "running")
        XCTAssertEqual(response.cpuCount, 4)
        XCTAssertEqual(response.memoryMB, 2_048)
        XCTAssertEqual(response.bootDiskId, "disk-1")
        XCTAssertEqual(response.networkId, "net-1")
        XCTAssertEqual(response.description, "A VM")
        XCTAssertEqual(response.uefi, true)
        XCTAssertEqual(response.tpmEnabled, false)
        XCTAssertEqual(response.macAddress, "52:54:00:12:34:56")
        XCTAssertEqual(response.pendingChanges, true)
        XCTAssertEqual(response.additionalDiskIds, ["disk-2", "disk-3"])
        XCTAssertEqual(response.sharedPaths, ["/Users/test/share"])
        XCTAssertEqual(response.portForwards?.count, 1)
        XCTAssertEqual(response.portForwards?.first?.guestPort, 22)
        XCTAssertEqual(response.portForwards?.first?.hostPort, 2_222)
    }

    func testVMResponseNilOptionals() {
        let vm = VM(
            id: "vm-1", name: "minimal", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1",
            isoId: nil, networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil,
            additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)

        XCTAssertNil(response.networkId)
        XCTAssertNil(response.description)
        XCTAssertNil(response.additionalDiskIds)
        XCTAssertNil(response.sharedPaths)
        XCTAssertNil(response.portForwards)
        XCTAssertNil(response.macAddress)
        // isoIds should be nil when no ISOs
        XCTAssertNil(response.isoIds)
        XCTAssertNil(response.isoId)
    }

    func testVMResponseIsoIdBackwardsCompat() {
        // When isoIds JSON column has values, isoId should be the first element
        let vm = VM(
            id: "vm-1", name: "iso-test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1",
            isoId: nil, isoIds: "[\"iso-1\",\"iso-2\"]",
            networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil,
            additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)
        XCTAssertEqual(response.isoId, "iso-1")
        XCTAssertEqual(response.isoIds, ["iso-1", "iso-2"])
    }

    func testVMResponseLegacyIsoId() {
        // When legacy isoId is set but isoIds is nil, should use legacy value
        let vm = VM(
            id: "vm-1", name: "legacy-iso", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1",
            isoId: "legacy-iso-1", isoIds: nil,
            networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil,
            additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)
        XCTAssertEqual(response.isoId, "legacy-iso-1")
        XCTAssertEqual(response.isoIds, ["legacy-iso-1"])
    }

    // MARK: - VMResponse Encodable

    func testVMResponseEncodesToJSON() throws {
        let vm = VM(
            id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-1",
            isoId: nil, networkId: nil, cloudInitPath: nil, vncPort: nil,
            description: nil, bootOrder: nil, displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = VMResponse(from: vm)
        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["id"] as? String, "vm-1")
        XCTAssertEqual(dict?["memoryMB"] as? Int, 1_024)
        XCTAssertEqual(dict?["uefi"] as? Bool, true)
    }

    // MARK: - ImageResponse

    func testImageResponseFromVMImage() {
        let image = VMImage(
            id: "img-1", name: "Ubuntu 24.04", imageType: "cloud-image", arch: "arm64",
            path: "/data/images/img-1.qcow2", sizeBytes: 1_073_741_824,
            status: "ready", error: nil,
            sourceUrl: "https://example.com/ubuntu.qcow2",
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = ImageResponse(from: image)

        XCTAssertEqual(response.id, "img-1")
        XCTAssertEqual(response.name, "Ubuntu 24.04")
        XCTAssertEqual(response.imageType, "cloud-image")
        XCTAssertEqual(response.arch, "arm64")
        XCTAssertEqual(response.status, "ready")
        XCTAssertEqual(response.sizeBytes, 1_073_741_824)
        XCTAssertEqual(response.sourceUrl, "https://example.com/ubuntu.qcow2")
        XCTAssertNil(response.error)
    }

    func testImageResponseWithError() {
        let image = VMImage(
            id: "img-2", name: "Failed", imageType: "iso", arch: "arm64",
            path: nil, sizeBytes: nil,
            status: "error", error: "Download failed",
            sourceUrl: "https://example.com/bad.iso",
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = ImageResponse(from: image)

        XCTAssertEqual(response.status, "error")
        XCTAssertEqual(response.error, "Download failed")
        XCTAssertNil(response.sizeBytes)
    }

    // MARK: - TemplateResponse

    func testTemplateResponseFromVMTemplate() {
        let template = VMTemplate(
            id: "tpl-1", slug: "ubuntu-server",
            name: "Ubuntu Server", description: "A server template",
            category: "linux", icon: "ubuntu",
            imageSlug: "ubuntu-24.04",
            cpuCount: 2, memoryMB: 2_048, diskSizeGB: 20,
            portForwards: "[{\"protocol\":\"tcp\",\"hostPort\":2222,\"guestPort\":22}]",
            networkMode: "nat",
            inputs:
            "[{\"id\":\"hostname\",\"label\":\"Hostname\",\"type\":\"text\",\"default\":\"ubuntu\",\"required\":true}]",
            userDataTemplate: "#cloud-config\nhostname: {{hostname}}",
            isBuiltIn: true, repositoryId: nil,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
        )

        let response = TemplateResponse(from: template)

        XCTAssertEqual(response.id, "tpl-1")
        XCTAssertEqual(response.slug, "ubuntu-server")
        XCTAssertEqual(response.name, "Ubuntu Server")
        XCTAssertEqual(response.category, "linux")
        XCTAssertEqual(response.cpuCount, 2)
        XCTAssertEqual(response.memoryMB, 2_048)
        XCTAssertEqual(response.diskSizeGB, 20)
        XCTAssertEqual(response.networkMode, "nat")
        XCTAssertEqual(response.isBuiltIn, true)
        XCTAssertEqual(response.portForwards?.count, 1)
        XCTAssertEqual(response.inputs.count, 1)
        XCTAssertEqual(response.inputs.first?.id, "hostname")
    }

    // MARK: - RepositoryResponse

    func testRepositoryResponseFromImageRepository() {
        let repo = ImageRepository(
            id: "repo-1", name: "Official", url: "https://example.com/repo.json",
            isBuiltIn: true, repoType: "images",
            lastSyncedAt: "2025-06-01T00:00:00Z", lastError: nil,
            syncStatus: "idle",
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-06-01T00:00:00Z",
        )

        let response = RepositoryResponse(from: repo)

        XCTAssertEqual(response.id, "repo-1")
        XCTAssertEqual(response.name, "Official")
        XCTAssertEqual(response.isBuiltIn, true)
        XCTAssertEqual(response.repoType, "images")
        XCTAssertEqual(response.syncStatus, "idle")
        XCTAssertNotNil(response.lastSyncedAt)
        XCTAssertNil(response.lastError)
    }

    // MARK: - RepositoryImageResponse

    func testRepositoryImageResponseFromModel() {
        let img = RepositoryImage(
            id: "ri-1", repositoryId: "repo-1", slug: "ubuntu-24.04",
            name: "Ubuntu 24.04", description: "LTS release",
            imageType: "cloud-image", arch: "arm64",
            version: "24.04", downloadUrl: "https://example.com/ubuntu.qcow2",
            sizeBytes: 1_073_741_824,
        )

        let response = RepositoryImageResponse(from: img)

        XCTAssertEqual(response.id, "ri-1")
        XCTAssertEqual(response.repositoryId, "repo-1")
        XCTAssertEqual(response.slug, "ubuntu-24.04")
        XCTAssertEqual(response.name, "Ubuntu 24.04")
        XCTAssertEqual(response.imageType, "cloud-image")
        XCTAssertEqual(response.downloadUrl, "https://example.com/ubuntu.qcow2")
    }

    // MARK: - GuestInfoResponse

    func testGuestInfoResponseFromResult() {
        let result = GuestInfoResult(
            available: true,
            ipAddresses: ["10.0.0.5", "fd00::5"],
            macAddress: "52:54:00:12:34:56",
            ipSource: "guest-agent",
            hostname: "ubuntu-vm",
            osName: "Ubuntu",
            osVersion: "24.04",
            osId: "ubuntu",
            kernelVersion: "6.5.0",
            kernelRelease: "6.5.0-44-generic",
            machine: "aarch64",
            timezone: "UTC",
            timezoneOffset: 0,
            users: nil,
            filesystems: nil,
        )

        let response = GuestInfoResponse(from: result)

        XCTAssertTrue(response.available)
        XCTAssertEqual(response.ipAddresses, ["10.0.0.5", "fd00::5"])
        XCTAssertEqual(response.macAddress, "52:54:00:12:34:56")
        XCTAssertEqual(response.ipSource, "guest-agent")
        XCTAssertEqual(response.hostname, "ubuntu-vm")
        XCTAssertEqual(response.osName, "Ubuntu")
        XCTAssertEqual(response.osVersion, "24.04")
    }

    func testGuestInfoResponseUnavailable() {
        let result = GuestInfoResult(
            available: false,
            ipAddresses: [],
            macAddress: nil,
            ipSource: "none",
            hostname: nil,
            osName: nil,
            osVersion: nil,
            osId: nil,
            kernelVersion: nil,
            kernelRelease: nil,
            machine: nil,
            timezone: nil,
            timezoneOffset: nil,
            users: nil,
            filesystems: nil,
        )

        let response = GuestInfoResponse(from: result)

        XCTAssertFalse(response.available)
        XCTAssertTrue(response.ipAddresses.isEmpty)
        XCTAssertNil(response.hostname)
    }
}
