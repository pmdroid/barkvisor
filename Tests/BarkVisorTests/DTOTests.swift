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
            cpuCount: 4, memoryMb: 2_048, bootDiskId: "disk-1", networkId: "net-1", cloudInitPath: nil,
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
        #expect(response.spec.metadata.name == "test-vm")
        #expect(response.spec.spec.resources.cpu == 4)
        #expect(response.spec.spec.guestType == "linux-arm64")
        #expect(response.status.state == .running)
        #expect(response.status.pendingChanges)
        #expect(response.health == .running)
        #expect(response.status.health == .running)
        #expect(response.status.healthError == nil)
        #expect(response.status.backend == WorkloadBackendProjector.project(guestType: "linux-arm64"))
        #expect(response.status.backend.qemuBinary == "qemu-system-aarch64")
        #expect(response.status.backend.accelerator == QEMUBuilder.accelerator)
    }

    @Test func `vm response nil optionals`() {
        let vm = VM(
            id: "vm-1", name: "minimal", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1", networkId: nil, cloudInitPath: nil,
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
        #expect(response.health == .stopped)
        #expect(response.session == nil)
    }

    @Test func `vm response includes coding session view`() throws {
        var vm = VM(
            id: "vm-agent", name: "coder", vmType: "linux-arm64", state: "running",
            cpuCount: 2, memoryMb: 2_048, bootDiskId: "disk-1", networkId: nil, cloudInitPath: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: true, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            workloadClass: "agent",
            createdAt: "2026-08-23T12:00:00Z", updatedAt: "2026-08-23T12:00:00Z",
        )
        var session = CodingAgentLifecycle.seed(
            ttlSeconds: 3_600, grant: "home-ollama", cloudImageId: "img-1", diskSizeGB: 20,
        )
        let started = try #require(iso8601.date(from: "2026-08-23T12:00:00Z"))
        CodingAgentLifecycle.beginClock(&session, now: started)
        vm.setSession(session)
        let response = VMResponse(from: vm)
        #expect(response.session?.expiryAction == "stop")
        #expect(response.session?.actions == ["resume", "reset", "burn"])
        #expect(response.session?.grant == "home-ollama")
        #expect(response.session?.ttlSeconds == 3_600)
        session.receipt = CodingAgentLifecycle.makeReceipt(
            now: started, reason: "stop", lastGitPushAt: nil,
        )
        vm.setSession(session)
        #expect(VMResponse(from: vm).session?.receipt == nil)
        vm.state = "stopped"
        #expect(VMResponse(from: vm).session?.receipt != nil)
    }

    @Test func `vm response iso id backwards compat`() {
        let vm = VM(
            id: "vm-1", name: "iso-test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1", isoIds: "[\"iso-1\",\"iso-2\"]",
            networkId: nil, cloudInitPath: nil,
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

    @Test func `vm response failed qemu includes last error`() {
        let vm = VM(
            id: "vm-1", name: "dead", vmType: "linux-arm64", state: "error",
            cpuCount: 1, memoryMb: 512, bootDiskId: "disk-1", networkId: nil, cloudInitPath: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: false, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )
        let response = VMResponse(
            from: vm,
            signals: WorkloadHealthSignals(lastError: "QEMU exited with status 1"),
        )
        #expect(response.health == .failed)
        #expect(response.status.health == .failed)
        #expect(response.status.healthError == "QEMU exited with status 1")
    }

    @Test func `vm response encodes spec and status`() throws {
        let vm = VM(
            id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-1", networkId: nil, cloudInitPath: nil,
            description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
            uefi: true, tpmEnabled: false,
            macAddress: nil, sharedPaths: nil, portForwards: nil,
            autoCreated: false, pendingChanges: false,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
        )
        let response = VMResponse(from: vm)
        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["spec"] is [String: Any])
        #expect(dict?["status"] is [String: Any])
        let status = dict?["status"] as? [String: Any]
        #expect(status?["state"] as? String == "stopped")
        #expect(status?["generation"] as? Int == 1)
        #expect(status?["health"] as? String == "stopped")
        #expect(dict?["health"] as? String == "stopped")
    }

    // MARK: - VMResponse Encodable

    @Test func `vm response encodes to JSON`() throws {
        let vm = VM(
            id: "vm-1", name: "test", vmType: "linux-arm64", state: "stopped",
            cpuCount: 2, memoryMb: 1_024, bootDiskId: "disk-1", networkId: nil, cloudInitPath: nil,
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
            sha256: "deadbeef",
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
        #expect(response.sha256 == "deadbeef")
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
        #expect(response.architectures.isEmpty || response.compatible)
    }

    @Test func `template response compatible uses features and min memory`() {
        let template = VMTemplate(
            id: "tpl-pi", slug: "pi-hole", name: "Pi-hole", description: nil,
            category: "networking", icon: "shield",
            imageSlug: "ubuntu-24.04-x86_64",
            cpuCount: 1, memoryMB: 512, diskSizeGB: 8,
            portForwards: "[]", networkMode: "bridged", inputs: "[]",
            userDataTemplate: "", isBuiltIn: true, repositoryId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            architecturesJson: #"["x86_64"]"#,
            minMemoryMB: 512,
            requiredFeaturesJson: #"["bridgedNetworking"]"#,
            imageByArchJson: #"{"x86_64":"ubuntu-24.04-x86_64"}"#,
        )

        let matching = TemplateResponse(
            from: template, host: dtoTemplateHost(arch: "x86_64", bridged: true),
        )
        #expect(matching.compatible)
        #expect(matching.resolvedImageSlug == "ubuntu-24.04-x86_64")

        let missingBridge = TemplateResponse(
            from: template, host: dtoTemplateHost(arch: "x86_64", bridged: false),
        )
        #expect(!missingBridge.compatible)

        let lowHostRAM = TemplateResponse(
            from: template,
            host: dtoTemplateHost(arch: "x86_64", bridged: true, memoryTotalMB: 256),
        )
        #expect(!lowHostRAM.compatible)
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
        #expect(response.listeningPorts == nil)
        #expect(response.portsCollectedAt == nil)
    }

    @Test func `guest info response carries listening ports`() {
        let ssh = GuestListeningPortDTO(
            proto: "tcp", address: "0.0.0.0", port: 22, scope: "network", label: "SSH",
        )
        let result = GuestInfoResult(
            available: true, ipAddresses: ["10.0.0.5"],
            macAddress: nil, ipSource: "guest-agent",
            hostname: nil, osName: nil, osVersion: nil,
            osId: nil, kernelVersion: nil, kernelRelease: nil, machine: nil,
            timezone: nil, timezoneOffset: nil, users: nil, filesystems: nil,
            listeningPorts: [ssh], portsCollectedAt: "2026-08-18T00:00:00Z",
        )
        let response = GuestInfoResponse(from: result)
        #expect(response.listeningPorts?.count == 1)
        #expect(response.listeningPorts?.first?.port == 22)
        #expect(response.listeningPorts?.first?.label == "SSH")
        #expect(response.portsCollectedAt == "2026-08-18T00:00:00Z")
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
        #expect(response.listeningPorts == nil)
    }
}

private func dtoTemplateHost(
    arch: String, bridged: Bool, memoryTotalMB: Int = 8_192,
) -> HostInventory {
    HostInventory(
        schemaVersion: 1,
        hostId: "test-host-id",
        displayName: "test-host",
        agent: AgentInfo(version: "test"),
        platform: PlatformInfo(os: "macOS", osVersion: "test", arch: arch, hostname: "test-host"),
        resources: ResourcesInfo(
            cpuCount: 4, memoryTotalMB: memoryTotalMB, memoryUsedMB: 1_024, cpuLoadPercent: 1,
        ),
        storage: [],
        networking: NetworkingInfo(interfaces: []),
        virtualization: VirtualizationInfo(
            accelerator: "hvf",
            qemuCPUModel: "host",
            defaultGuestArch: arch == "arm64" ? "aarch64" : "x86_64",
            features: VirtualizationFeatures(
                bridgedNetworking: bridged,
                managedBridgeDaemon: bridged,
                usbPassthrough: true,
                inAppUpdate: true,
                kvmDevice: false,
                qemuBridgeHelper: false,
            ),
        ),
        guestTypes: [],
        collectedAt: "2026-08-12T00:00:00Z",
    )
}
