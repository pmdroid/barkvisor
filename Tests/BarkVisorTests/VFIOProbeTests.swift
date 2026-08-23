import Foundation
import Testing
@testable import BarkVisorCore

@Suite("VFIO probe (PAS-274)")
struct VFIOProbeTests {
    @Test func `non-linux live probe is empty`() {
        #if !os(Linux)
            let facts = VFIOProbe.live()
            #expect(facts.iommuGroupCount == 0)
            #expect(!facts.vfioPresent)
            #expect(!facts.kvmDevice)
            #expect(facts.gpuCount == 0)
            #expect(!VFIOProbe.vfioSupported(os: "macOS", facts: facts))
            #expect(!VFIOProbe.gpuPassthroughSupported(os: "macOS", facts: facts))
            #expect(VFIOProbe.gpuPassthroughReason(os: "macOS", facts: facts) == .osUnsupported)
        #endif
    }

    @Test func `collect reads iommu groups vfio and gpu class`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vfio-probe-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let groups = root.appendingPathComponent("iommu_groups")
        try writePCIDevice(
            groups: groups, group: "0", bdf: "0000:00:02.0", pciClass: "0x030000\n",
        )
        try writePCIDevice(
            groups: groups, group: "1", bdf: "0000:00:1f.0", pciClass: "0x060100\n",
        )
        let vfioPci = root.appendingPathComponent("vfio-pci")
        try FileManager.default.createDirectory(at: vfioPci, withIntermediateDirectories: true)
        let vfioDev = root.appendingPathComponent("vfio")
        try Data().write(to: vfioDev)
        let kvm = root.appendingPathComponent("kvm")
        try Data().write(to: kvm)

        let facts = VFIOProbe.collect(
            from: VFIOProbePaths(
                iommuGroups: groups.path,
                vfioPciDriver: vfioPci.path,
                vfioModule: root.appendingPathComponent("missing-module").path,
                vfioDevice: vfioDev.path,
                kvmDevice: kvm.path,
            ),
        )
        #expect(facts.iommuGroupCount == 2)
        #expect(facts.vfioPciPresent)
        #expect(facts.vfioDevicePresent)
        #expect(facts.kvmDevice)
        #expect(facts.gpuCount == 1)
        #expect(VFIOProbe.vfioSupported(os: "Linux", facts: facts))
        #expect(VFIOProbe.gpuPassthroughSupported(os: "Linux", facts: facts))
        #expect(VFIOProbe.gpuPassthroughReason(os: "Linux", facts: facts) == nil)
    }

    @Test func `reason order is kvm then iommu then vfio then gpu`() {
        let base = VFIOHostFacts(
            iommuGroupCount: 2,
            vfioPciPresent: true,
            vfioDevicePresent: true,
            kvmDevice: true,
            gpuCount: 1,
        )
        #expect(VFIOProbe.gpuPassthroughSupported(os: "Linux", facts: base))

        var noKvm = base
        noKvm.kvmDevice = false
        #expect(VFIOProbe.gpuPassthroughReason(os: "Linux", facts: noKvm) == .kvmMissing)
        #expect(VFIOProbe.vfioSupported(os: "Linux", facts: noKvm))

        var noIommu = base
        noIommu.iommuGroupCount = 0
        #expect(VFIOProbe.gpuPassthroughReason(os: "Linux", facts: noIommu) == .iommuMissing)
        #expect(VFIOProbe.vfioReason(os: "Linux", facts: noIommu) == .iommuMissing)

        var noVfio = base
        noVfio.vfioPciPresent = false
        noVfio.vfioDevicePresent = false
        #expect(VFIOProbe.gpuPassthroughReason(os: "Linux", facts: noVfio) == .vfioMissing)
        #expect(VFIOProbe.vfioReason(os: "Linux", facts: noVfio) == .vfioMissing)

        var noGpu = base
        noGpu.gpuCount = 0
        #expect(VFIOProbe.gpuPassthroughReason(os: "Linux", facts: noGpu) == .gpuMissing)
        #expect(VFIOProbe.vfioSupported(os: "Linux", facts: noGpu))
    }

    @Test func `display class is pci base 03`() {
        #expect(VFIOProbe.isDisplayClass("0x030000"))
        #expect(VFIOProbe.isDisplayClass("0x030200\n"))
        #expect(VFIOProbe.isDisplayClass("038000"))
        #expect(!VFIOProbe.isDisplayClass("0x020000"))
        #expect(!VFIOProbe.isDisplayClass(""))
    }

    @Test func `inventory omits vfioProbe on old json`() throws {
        let inv = HostInventory(
            schemaVersion: 1,
            hostId: "h",
            displayName: "h",
            agent: AgentInfo(version: "t"),
            platform: PlatformInfo(os: "Linux", osVersion: "t", arch: "x86_64", hostname: "h"),
            resources: ResourcesInfo(cpuCount: 1, memoryTotalMB: 1, memoryUsedMB: 0, cpuLoadPercent: 0),
            storage: [],
            networking: NetworkingInfo(interfaces: []),
            virtualization: VirtualizationInfo(
                accelerator: "kvm",
                qemuCPUModel: "host",
                defaultGuestArch: "x86_64",
                features: VirtualizationFeatures(
                    bridgedNetworking: true,
                    managedBridgeDaemon: false,
                    usbPassthrough: true,
                    inAppUpdate: false,
                    kvmDevice: true,
                    qemuBridgeHelper: true,
                ),
            ),
            guestTypes: [],
            collectedAt: "2026-08-12T00:00:00Z",
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inv)) as? [String: Any]
        var virt = object?["virtualization"] as? [String: Any]
        virt?.removeValue(forKey: "vfioProbe")
        var features = virt?["features"] as? [String: Any]
        features?.removeValue(forKey: "gpuPassthrough")
        features?.removeValue(forKey: "vfio")
        virt?["features"] = features
        object?["virtualization"] = virt
        let data = try JSONSerialization.data(withJSONObject: object as Any)
        let decoded = try JSONDecoder().decode(HostInventory.self, from: data)
        #expect(decoded.virtualization.vfioProbe.iommuGroupCount == 0)
        #expect(decoded.virtualization.features.gpuPassthrough == false)
        #expect(decoded.virtualization.features.vfio == false)
    }

    private func writePCIDevice(groups: URL, group: String, bdf: String, pciClass: String) throws {
        let dir = groups
            .appendingPathComponent(group)
            .appendingPathComponent("devices")
            .appendingPathComponent(bdf)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pciClass.write(
            to: dir.appendingPathComponent("class"),
            atomically: true,
            encoding: .utf8,
        )
    }
}
