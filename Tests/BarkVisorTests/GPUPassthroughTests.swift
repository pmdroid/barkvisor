import Foundation
import Testing
@testable import BarkVisorCore

@Suite("GPU passthrough (PAS-275)")
struct GPUPassthroughTests {
    @Test func `pci address validation`() {
        #expect(GPUPassthroughService.isPCIAddress("0000:01:00.0"))
        #expect(GPUPassthroughService.isPCIAddress("0000:03:00.1"))
        #expect(!GPUPassthroughService.isPCIAddress("01:00.0"))
        #expect(!GPUPassthroughService.isPCIAddress("0000:01:00.8"))
        #expect(!GPUPassthroughService.isPCIAddress("not-a-bdf"))
        #expect(GPUPassthroughService.normalizePCIAddress("0000:01:00.0") == "0000:01:00.0")
    }

    @Test func `list display devices includes iommu group companions`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gpu-list-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let groups = root.appendingPathComponent("iommu_groups")
        try writePCIDevice(
            groups: groups, group: "14", bdf: "0000:01:00.0", pciClass: "0x030000\n",
            vendor: "0x10de\n", device: "0x2684\n", driver: "nvidia",
        )
        try writePCIDevice(
            groups: groups, group: "14", bdf: "0000:01:00.1", pciClass: "0x040300\n",
            vendor: "0x10de\n", device: "0x22ba\n", driver: "snd_hda_intel",
        )
        let vfioPci = root.appendingPathComponent("vfio-pci")
        try FileManager.default.createDirectory(at: vfioPci, withIntermediateDirectories: true)
        let vfioDev = root.appendingPathComponent("vfio")
        try Data().write(to: vfioDev)
        let kvm = root.appendingPathComponent("kvm")
        try Data().write(to: kvm)

        let paths = VFIOProbePaths(
            iommuGroups: groups.path,
            vfioPciDriver: vfioPci.path,
            vfioModule: root.appendingPathComponent("missing-module").path,
            vfioDevice: vfioDev.path,
            kvmDevice: kvm.path,
        )
        let listed = GPUDeviceService.listDevices(
            from: paths, hostOllamaReachable: false,
        )
        #expect(listed.count == 1)
        #expect(listed[0].pciAddress == "0000:01:00.0")
        #expect(listed[0].iommuGroup == "14")
        #expect(listed[0].groupAddresses == ["0000:01:00.0", "0000:01:00.1"])
        #expect(listed[0].attachable)
        #expect(listed[0].guestOllamaPath == GPUPassthroughService.guestOllamaPath)
        #expect(!listed[0].inUseByHost)
    }

    @Test func `host ollama blocks attach on a host-bound card`() throws {
        let host = HostGPUDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            name: "NVIDIA",
            driver: "nvidia",
            vfioBound: false,
            inUseByHost: true,
            attachable: false,
            excludedReason: GPUPassthroughService.hostGuestExclusiveMessage,
            groupAddresses: ["0000:01:00.0"],
        )
        let err = #expect(throws: BarkVisorError.self) {
            _ = try GPUPassthroughService.resolveAttachable(
                deviceId: host.pciAddress, hostDevices: [host],
            )
        }
        if case let .forbidden(message) = err {
            #expect(message.contains("host"))
            #expect(message.contains("guest"))
        } else {
            Issue.record("expected forbidden, got \(String(describing: err))")
        }
    }

    @Test func `same card cannot attach to two workloads`() throws {
        let stored = GPUPassthroughDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            label: "NVIDIA",
            groupAddresses: ["0000:01:00.0", "0000:01:00.1"],
        )
        let occupant = makeVM(gpu: [stored])
        let other = GPUPassthroughDevice(
            pciAddress: "0000:01:00.1",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "22ba",
            groupAddresses: ["0000:01:00.0", "0000:01:00.1"],
        )
        let err = #expect(throws: BarkVisorError.self) {
            try GPUPassthroughService.assertUnclaimed(devices: [other], vms: [occupant])
        }
        if case let .conflict(message) = err {
            #expect(message.contains("gpu-vm"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `empty iommu groups lists nothing`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gpu-empty-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VFIOProbePaths(
            iommuGroups: root.appendingPathComponent("missing-groups").path,
            vfioPciDriver: root.appendingPathComponent("vfio-pci").path,
            vfioModule: root.appendingPathComponent("module").path,
            vfioDevice: root.appendingPathComponent("vfio").path,
            kvmDevice: root.appendingPathComponent("kvm").path,
        )
        #expect(GPUDeviceService.listDevices(from: paths, hostOllamaReachable: true).isEmpty)
    }

    @Test func `qemu vfio args cover the iommu group`() throws {
        let gpu = WorkloadGPUDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            groupAddresses: ["0000:01:00.0", "0000:01:00.1"],
        )
        let args = try QEMUBuilder.vfioPCIArgs(gpu: [gpu], bind: false)
        #expect(args == [
            "-device", "vfio-pci,host=0000:01:00.0,id=vfio-pt-0",
            "-device", "vfio-pci,host=0000:01:00.1,id=vfio-pt-1",
        ])
    }

    @Test func `qemu vfio args reject junk addresses`() {
        let gpu = WorkloadGPUDevice(
            pciAddress: "not-pci",
            iommuGroup: "1",
            vendorId: "10de",
            deviceId: "1234",
            groupAddresses: ["not-pci"],
        )
        #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.vfioPCIArgs(gpu: [gpu], bind: false)
        }
    }

    @Test func `macOS live attach fails closed`() {
        #if !os(Linux)
            let err = #expect(throws: BarkVisorError.self) {
                try PlatformCapabilities.requireGPUPassthrough()
            }
            if case let .unsupportedFeature(feature) = err {
                #expect(feature == .gpuPassthrough)
            } else {
                Issue.record("expected unsupportedFeature, got \(String(describing: err))")
            }
            #expect(GPUDeviceService.listDevices(hostOllamaReachable: true).isEmpty)
        #endif
    }

    @Test func `guest ollama path is loopback not host grant`() {
        #expect(GPUPassthroughService.guestOllamaPath == "http://127.0.0.1:11434/v1")
        #expect(CodingAgentImage.guestOllamaBaseURL == GPUPassthroughService.guestOllamaPath)
        #expect(CodingAgentImage.guestOllamaBaseURL != CodingAgentImage.homeOllamaGrantURL)
        let yaml = CodingAgentImage.userData(
            openaiBaseURL: CodingAgentImage.guestOllamaBaseURL,
            installGuestOllama: true,
        )
        #expect(yaml.contains("127.0.0.1:11434"))
        #expect(yaml.contains("barkvisor-guest-ollama"))
        #expect(!yaml.contains("10.0.2.2:11434"))
    }

    @Test func `host ollama grant is skipped when a gpu is attached`() {
        #expect(
            AgentNetworkCage.allowHostOllama(
                userData: "OPENAI_BASE_URL=http://10.0.2.2:11434/v1",
            ),
        )
        let gpu = WorkloadGPUDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "1",
            vendorId: "10de",
            deviceId: "1234",
        )
        #expect(!gpu.pciAddress.isEmpty)
    }

    private func makeVM(gpu: [GPUPassthroughDevice]) -> VM {
        let cpu = min(2, max(1, PlatformHost.cpuCount))
        return VM(
            id: "vm-gpu-1",
            name: "gpu-vm",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: cpu,
            memoryMb: 1_024,
            bootDiskId: "disk-1",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            usbDevices: nil,
            gpuDevices: JSONColumnCoding.encode(gpu),
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-08-23T00:00:00Z",
            updatedAt: "2026-08-23T00:00:00Z",
        )
    }

    private func writePCIDevice(
        groups: URL,
        group: String,
        bdf: String,
        pciClass: String,
        vendor: String,
        device: String,
        driver: String?,
    ) throws {
        let dir = groups
            .appendingPathComponent(group)
            .appendingPathComponent("devices")
            .appendingPathComponent(bdf)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pciClass.write(to: dir.appendingPathComponent("class"), atomically: true, encoding: .utf8)
        try vendor.write(to: dir.appendingPathComponent("vendor"), atomically: true, encoding: .utf8)
        try device.write(to: dir.appendingPathComponent("device"), atomically: true, encoding: .utf8)
        if let driver {
            let driverDir = groups.deletingLastPathComponent().appendingPathComponent("drivers")
                .appendingPathComponent(driver)
            try FileManager.default.createDirectory(at: driverDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent("driver").path,
                withDestinationPath: driverDir.path,
            )
        }
    }
}
