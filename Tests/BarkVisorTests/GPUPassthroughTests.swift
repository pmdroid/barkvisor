import Foundation
import GRDB
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
        let listed = GPUDeviceService.listDevices(from: paths)
        #expect(listed.count == 1)
        #expect(listed[0].pciAddress == "0000:01:00.0")
        #expect(listed[0].iommuGroup == "14")
        #expect(listed[0].groupAddresses == ["0000:01:00.0", "0000:01:00.1"])
        #expect(listed[0].attachable)
        #expect(listed[0].guestOllamaPath == GPUPassthroughService.guestOllamaPath)
        #expect(listed[0].inUseByHost)
        #expect(listed[0].excludedReason == GPUPassthroughService.hostGuestExclusiveMessage)
    }

    @Test func `host occupancy is the gpu driver not an ollama probe`() {
        let nvidia = VFIODisplayDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            driver: "nvidia",
            groupAddresses: ["0000:01:00.0"],
        )
        let occupied = GPUDeviceService.project(nvidia, iommuReady: true)
        #expect(occupied.inUseByHost)
        #expect(occupied.attachable)
        #expect(occupied.excludedReason == GPUPassthroughService.hostGuestExclusiveMessage)

        let vfio = VFIODisplayDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            driver: "vfio-pci",
            groupAddresses: ["0000:01:00.0"],
        )
        let guest = GPUDeviceService.project(vfio, iommuReady: true)
        #expect(!guest.inUseByHost)
        #expect(guest.vfioBound)
        #expect(guest.attachable)
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
        #expect(GPUDeviceService.listDevices(from: paths).isEmpty)
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
            #expect(GPUDeviceService.listDevices().isEmpty)
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

    @Test func `post-create gpu user-data installs guest ollama`() throws {
        let attached = CodingAgentImage.userDataForGPU(gpuAttached: true)
        try CloudInitService.validateUserData(attached)
        #expect(attached.contains("barkvisor-guest-ollama"))
        #expect(attached.contains("127.0.0.1:11434"))
        #expect(!attached.contains("10.0.2.2:11434"))
        #expect(CodingAgentImage.isManagedUserData(attached))
        #expect(CodingAgentImage.cloudInitInstanceID(vmID: "vm-1", gpuAttached: true) == "vm-1-gpu")

        let detached = CodingAgentImage.userDataForGPU(gpuAttached: false)
        try CloudInitService.validateUserData(detached)
        #expect(!detached.contains("barkvisor-guest-ollama"))
        #expect(detached.contains("10.0.2.2:11434"))
        #expect(CodingAgentImage.cloudInitInstanceID(vmID: "vm-1", gpuAttached: false) == "vm-1")

        let gpu = GPUPassthroughDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
        )
        let params = CreateVMParams(
            name: "coder",
            vmType: "linux-arm64",
            cpuCount: 2,
            memoryMB: 1_024,
            diskSizeGB: 10,
            cloudImageId: "img-1",
            gpuDevices: [gpu],
        )
        let applied = try CodingAgentImage.applyingCreateDefaults(
            params: params, imageName: "Coding Agent",
        )
        #expect(applied.cloudInit?.userData?.contains("barkvisor-guest-ollama") == true)
        #expect(applied.cloudInit?.userData?.contains("127.0.0.1:11434") == true)
    }

    @Test func `vfio bind verifies the driver symlink not the write-only bind node`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.exists.insert("/sys/bus/pci/devices/\(address)")
        fake.driver[address] = "nvidia"
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        try VFIOBinder.bind(addresses: [address], paths: paths, sysfs: fake.sysfs)
        #expect(fake.driver[address] == "vfio-pci")
        #expect(fake.writes.contains { $0.path.hasSuffix("driver_override") && $0.text.contains("vfio-pci") })
        #expect(fake.writes.contains { $0.path.hasSuffix("/bind") && $0.path.contains("vfio-pci") })
        #expect(!fake.readBindNode)

        try VFIOBinder.unbind(addresses: [address], paths: paths, sysfs: fake.sysfs)
        #expect(fake.driver[address] != "vfio-pci")
        #expect(fake.writes.contains { $0.path.hasSuffix("/unbind") && $0.path.contains("vfio-pci") })
        #expect(fake.writes.contains { $0.path.hasSuffix("drivers_probe") })
    }

    @Test func `qemu vfio args bind path uses sysfs without reading bind`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.exists.insert("/sys/bus/pci/devices/\(address)")
        fake.driver[address] = "nvidia"
        let gpu = WorkloadGPUDevice(
            pciAddress: address,
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            groupAddresses: [address],
        )
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        let args = try QEMUBuilder.vfioPCIArgs(gpu: [gpu], bind: true, bindPaths: paths, sysfs: fake.sysfs)
        #expect(args == ["-device", "vfio-pci,host=\(address),id=vfio-pt-0"])
        #expect(fake.driver[address] == "vfio-pci")
        #expect(!fake.readBindNode)
    }

    @Test func `detach gpu is refused unless the workload is stopped`() {
        #expect(GPUPassthroughService.canDetach(state: "stopped"))
        #expect(GPUPassthroughService.canDetach(state: "error"))
        #expect(!GPUPassthroughService.canDetach(state: "running"))
        #expect(!GPUPassthroughService.canDetach(state: "starting"))
        #expect(!GPUPassthroughService.canDetach(state: "stopping"))
        let err = #expect(throws: BarkVisorError.self) {
            try GPUPassthroughService.assertCanDetach(state: "running")
        }
        if case let .conflict(message) = err {
            #expect(message.contains("Workload"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }
    }

    @Test func `detach gpu while running leaves the attachment in the db`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gpu-detach-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)

        let stored = GPUPassthroughDevice(
            pciAddress: "0000:01:00.0",
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            groupAddresses: ["0000:01:00.0", "0000:01:00.1"],
        )
        let vm = makeVM(gpu: [stored], state: "running")
        try await pool.write { db in
            try Disk(
                id: vm.bootDiskId,
                name: "boot",
                path: tmp.appendingPathComponent("boot.qcow2").path,
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: vm.id,
                autoCreated: false,
                status: "ready",
                createdAt: vm.createdAt,
            ).insert(db)
            try vm.insert(db)
        }

        let err = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.detachGPU(
                vmID: vm.id, deviceId: stored.pciAddress, db: pool,
            )
        }
        if case let .conflict(message) = err {
            #expect(message.contains("Workload"))
        } else {
            Issue.record("expected conflict, got \(String(describing: err))")
        }

        let still = try await pool.read { db in try VM.fetchOne(db, key: vm.id) }
        #expect(still?.decodedGPUDevices.map(\.pciAddress) == [stored.pciAddress])
    }

    @Test func `partial iommu group bind unbinds members already taken`() throws {
        let fake = FakeVFIOSysfs()
        let gpu = "0000:01:00.0"
        let audio = "0000:01:00.1"
        fake.exists.insert("/sys/bus/pci/devices/\(gpu)")
        fake.exists.insert("/sys/bus/pci/devices/\(audio)")
        fake.driver[gpu] = "nvidia"
        fake.driver[audio] = "snd_hda_intel"
        fake.skipBind.insert(audio)
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        #expect(throws: BarkVisorError.self) {
            try VFIOBinder.bind(addresses: [gpu, audio], paths: paths, sysfs: fake.sysfs)
        }
        #expect(fake.driver[gpu] != "vfio-pci")
        #expect(fake.driver[audio] != "vfio-pci")
    }

    @Test func `start failure after vfio bind unbinds the group`() throws {
        let fake = FakeVFIOSysfs()
        let gpu = "0000:01:00.0"
        let audio = "0000:01:00.1"
        fake.exists.insert("/sys/bus/pci/devices/\(gpu)")
        fake.exists.insert("/sys/bus/pci/devices/\(audio)")
        fake.driver[gpu] = "nvidia"
        fake.driver[audio] = "snd_hda_intel"
        let stored = GPUPassthroughDevice(
            pciAddress: gpu,
            iommuGroup: "14",
            vendorId: "10de",
            deviceId: "2684",
            groupAddresses: [gpu, audio],
        )
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        _ = try QEMUBuilder.vfioPCIArgs(
            gpu: [GPUPassthroughService.workload(from: stored)],
            bind: true,
            bindPaths: paths,
            sysfs: fake.sysfs,
        )
        #expect(fake.driver[gpu] == "vfio-pci")
        #expect(fake.driver[audio] == "vfio-pci")

        GPUPassthroughService.releaseVFIO([stored], paths: paths, sysfs: fake.sysfs)
        #expect(fake.driver[gpu] != "vfio-pci")
        #expect(fake.driver[audio] != "vfio-pci")
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

    private func makeVM(gpu: [GPUPassthroughDevice], state: String = "stopped") -> VM {
        let cpu = min(2, max(1, PlatformHost.cpuCount))
        return VM(
            id: "vm-gpu-1",
            name: "gpu-vm",
            vmType: "linux-arm64",
            state: state,
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

    private final class FakeVFIOSysfs: @unchecked Sendable {
        var exists: Set<String> = []
        var driver: [String: String] = [:]
        var writes: [(path: String, text: String)] = []
        var readBindNode = false
        var skipBind: Set<String> = []

        var sysfs: VFIOSysfs {
            VFIOSysfs(
                fileExists: { [weak self] path in self?.exists.contains(path) ?? false },
                currentDriver: { [weak self] address in self?.driver[address] },
                write: { [weak self] text, path in
                    guard let self else { return }
                    self.writes.append((path, text))
                    let addr = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if path.hasSuffix("/bind"), path.contains("vfio-pci") {
                        if self.skipBind.contains(addr) { return }
                        self.driver[addr] = "vfio-pci"
                    }
                    if path.hasSuffix("/unbind"), path.contains("vfio-pci") {
                        self.driver[addr] = nil
                    }
                    if path.hasSuffix("drivers_probe") {
                        if self.driver[addr] == nil {
                            self.driver[addr] = "nvidia"
                        }
                    }
                },
            )
        }
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
