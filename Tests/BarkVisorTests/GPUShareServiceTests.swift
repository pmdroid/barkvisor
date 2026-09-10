import Foundation
import Testing
@testable import BarkVisorCore

struct GPUShareServiceTests {
    @Test func `drm iGPU is attachable and nvidia skips dri`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCI(
            root: root, bdf: "0000:00:02.0", vendor: "0x8086\n", device: "0x46a6\n",
            pciClass: "0x030000\n", driver: "i915",
        )
        try writePCI(
            root: root, bdf: "0000:01:00.0", vendor: "0x10de\n", device: "0x2684\n",
            pciClass: "0x030000\n", driver: "nvidia",
        )
        try writeDRM(root: root, name: "renderD128", bdf: "0000:00:02.0")
        try writeDRM(root: root, name: "card0", bdf: "0000:00:02.0")
        try writeDRM(root: root, name: "renderD129", bdf: "0000:01:00.0")
        try writeDRM(root: root, name: "card1", bdf: "0000:01:00.0")
        let nvidia = NVIDIAShareFacts(
            present: true,
            toolkitPresent: true,
            gpus: [
                NVIDIAShareGPU(uuid: "GPU-aaaa", name: "NVIDIA RTX", pciAddress: "00000000:01:00.0"),
            ],
        )
        let listed = GPUShareService.list(from: paths(root), nvidia: nvidia)
        #expect(listed.count == 2)
        let intel = try #require(listed.first { $0.kind == HostGPUShareDevice.kindDRM })
        #expect(intel.id == "0000:00:02.0")
        #expect(intel.attachable)
        #expect(intel.renderNodes.contains { $0.hasSuffix("/renderD128") })
        #expect(intel.cardNodes.contains { $0.hasSuffix("/card0") })
        #expect(intel.label.contains("renderD128"))
        let nv = try #require(listed.first { $0.kind == HostGPUShareDevice.kindNVIDIA })
        #expect(nv.id == "GPU-aaaa")
        #expect(nv.attachable)
        #expect(nv.nvidiaUUID == "GPU-aaaa")
        #expect(nv.renderNodes.isEmpty)
    }

    @Test func `vfio bound gpu is listed and not selectable`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCI(
            root: root, bdf: "0000:02:00.0", vendor: "0x10de\n", device: "0x2204\n",
            pciClass: "0x030000\n", driver: "vfio-pci",
        )
        let listed = GPUShareService.list(from: paths(root), nvidia: .empty)
        #expect(listed.count == 1)
        #expect(!listed[0].attachable)
        #expect(listed[0].vfioBound)
        #expect(listed[0].excludedReason == GPUShareService.vfioBoundMessage)
    }

    @Test func `vm claimed gpu is not attachable`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCI(
            root: root, bdf: "0000:00:02.0", vendor: "0x8086\n", device: "0x46a6\n",
            pciClass: "0x030000\n", driver: "i915",
        )
        try writeDRM(root: root, name: "renderD128", bdf: "0000:00:02.0")
        let vm = VM(
            id: "vm-1",
            name: "coder",
            vmType: "linux-arm64",
            state: "running",
            cpuCount: 1,
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
            gpuDevices: JSONColumnCoding.encode([
                GPUPassthroughDevice(
                    pciAddress: "0000:00:02.0",
                    iommuGroup: "1",
                    vendorId: "8086",
                    deviceId: "46a6",
                ),
            ]),
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-09-09T00:00:00Z",
            updatedAt: "2026-09-09T00:00:00Z",
        )
        let listed = GPUShareService.list(from: paths(root), nvidia: .empty, vms: [vm])
        #expect(listed.count == 1)
        #expect(!listed[0].attachable)
        #expect(listed[0].claimedByVMName == "coder")
        #expect(listed[0].excludedReason == "Attached to coder")
    }

    @Test func `missing toolkit leaves nvidia listed but not attachable`() throws {
        let nvidia = NVIDIAShareFacts(
            present: true,
            toolkitPresent: false,
            gpus: [NVIDIAShareGPU(uuid: "GPU-bbbb", name: "NVIDIA", pciAddress: "0000:01:00.0")],
        )
        let listed = GPUShareService.list(
            from: paths(FileManager.default.temporaryDirectory),
            nvidia: nvidia,
        )
        #expect(listed.count == 1)
        #expect(!listed[0].attachable)
        #expect(listed[0].excludedReason == GPUShareService.toolkitMissingMessage)
        #expect(throws: BarkVisorError.self) {
            try GPUShareService.validate(
                [WorkloadGPUShare(id: "GPU-bbbb")],
                inventory: listed,
            )
        }
    }

    @Test func `attach plan keeps dri and omits unchecked nvidia`() throws {
        let intel = HostGPUShareDevice(
            id: "0000:00:02.0",
            kind: HostGPUShareDevice.kindDRM,
            name: "Intel",
            label: "Intel (renderD128)",
            renderNodes: ["/dev/dri/renderD128"],
            cardNodes: ["/dev/dri/card0"],
            attachable: true,
        )
        let nvidia = HostGPUShareDevice(
            id: "GPU-aaaa",
            kind: HostGPUShareDevice.kindNVIDIA,
            name: "NVIDIA",
            label: "NVIDIA (GPU-aaaa)",
            nvidiaUUID: "GPU-aaaa",
            attachable: true,
        )
        let both = try GPUShareService.attach(
            selected: [WorkloadGPUShare(id: intel.id), WorkloadGPUShare(id: nvidia.id)],
            inventory: [intel, nvidia],
        )
        #expect(both.driDevices.contains("/dev/dri/renderD128"))
        #expect(both.driDevices.contains("/dev/dri/card0"))
        #expect(both.nvidiaUUIDs == ["GPU-aaaa"])
        #expect(both.nvidiaRuntime)
        let igpuOnly = try GPUShareService.attach(
            selected: [WorkloadGPUShare(id: intel.id)],
            inventory: [intel, nvidia],
        )
        #expect(igpuOnly.nvidiaUUIDs.isEmpty)
        #expect(!igpuOnly.nvidiaRuntime)
    }

    @Test func `macos live list is empty`() {
        #if !os(Linux)
            #expect(GPUShareService.list().isEmpty)
        #endif
    }

    @Test func `nvidia bus id domain is trimmed`() {
        #expect(GPUShareService.normalizeNVIDIABusID("00000000:01:00.0") == "0000:01:00.0")
        #expect(NVIDIAShareProbe.parseCSV("GPU-1, RTX, 00000000:01:00.0").first?.pciAddress == "0000:01:00.0")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dri"), withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("drm"), withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pci"), withIntermediateDirectories: true,
        )
        return root
    }

    private func paths(_ root: URL) -> GPUSharePaths {
        GPUSharePaths(
            driDir: root.appendingPathComponent("dri").path,
            drmClass: root.appendingPathComponent("drm").path,
            pciDevices: root.appendingPathComponent("pci").path,
        )
    }

    private func writePCI(
        root: URL,
        bdf: String,
        vendor: String,
        device: String,
        pciClass: String,
        driver: String,
    ) throws {
        let dir = root.appendingPathComponent("pci").appendingPathComponent(bdf)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try vendor.write(to: dir.appendingPathComponent("vendor"), atomically: true, encoding: .utf8)
        try device.write(to: dir.appendingPathComponent("device"), atomically: true, encoding: .utf8)
        try pciClass.write(to: dir.appendingPathComponent("class"), atomically: true, encoding: .utf8)
        let driverDir = root.appendingPathComponent("drivers").appendingPathComponent(driver)
        try FileManager.default.createDirectory(at: driverDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("driver").path,
            withDestinationPath: driverDir.path,
        )
    }

    private func writeDRM(root: URL, name: String, bdf: String) throws {
        let node = root.appendingPathComponent("drm").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        let pci = root.appendingPathComponent("pci").appendingPathComponent(bdf)
        try FileManager.default.createSymbolicLink(
            atPath: node.appendingPathComponent("device").path,
            withDestinationPath: pci.path,
        )
        try Data().write(to: root.appendingPathComponent("dri").appendingPathComponent(name))
    }
}
