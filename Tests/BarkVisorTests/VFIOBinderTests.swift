import Foundation
import Testing
@testable import BarkVisorCore

@Suite("VFIO bind sysfs preflight")
struct VFIOBinderTests {
    @Test func `vfio bind verifies the driver symlink not the write-only bind node`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.addDevice(address, driver: "nvidia")
        fake.addVFIOPCIDriver()
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

    @Test func `vfio bind without the module names the driver path and cause`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.addDevice(address, driver: "nvidia")
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        let err = #expect(throws: BarkVisorError.self) {
            try VFIOBinder.bind(addresses: [address], paths: paths, sysfs: fake.sysfs)
        }
        if case let .forbidden(message) = err {
            #expect(message.contains("/sys/bus/pci/drivers/vfio-pci"))
            #expect(message.contains("vfio-pci kernel module is not loaded"))
        } else {
            Issue.record("expected forbidden, got \(String(describing: err))")
        }
        #expect(fake.writes.isEmpty)
        #expect(fake.driver[address] == "nvidia")
    }

    @Test func `vfio bind with a missing bind node names the exact path`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.addDevice(address, driver: "nvidia")
        fake.addVFIOPCIDriver()
        fake.exists.remove("/sys/bus/pci/drivers/vfio-pci/bind")
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        let err = #expect(throws: BarkVisorError.self) {
            try VFIOBinder.bind(addresses: [address], paths: paths, sysfs: fake.sysfs)
        }
        if case let .forbidden(message) = err {
            #expect(message.contains("/sys/bus/pci/drivers/vfio-pci/bind"))
            #expect(message.contains("does not exist"))
            #expect(message.contains("bind node is missing from sysfs"))
            #expect(!message.contains("kernel module is not loaded"))
        } else {
            Issue.record("expected forbidden, got \(String(describing: err))")
        }
        #expect(fake.writes.isEmpty)
        #expect(fake.driver[address] == "nvidia")
    }

    @Test func `vfio bind without an iommu group names the group path`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.addDevice(address, driver: "nvidia")
        fake.addVFIOPCIDriver()
        fake.exists.remove("/sys/bus/pci/devices/\(address)/iommu_group")
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        let err = #expect(throws: BarkVisorError.self) {
            try VFIOBinder.bind(addresses: [address], paths: paths, sysfs: fake.sysfs)
        }
        if case let .forbidden(message) = err {
            #expect(message.contains("/sys/bus/pci/devices/\(address)/iommu_group"))
            #expect(message.contains("IOMMU"))
        } else {
            Issue.record("expected forbidden, got \(String(describing: err))")
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func `vfio bind write failure names the full sysfs path`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.addDevice(address, driver: "nvidia")
        fake.addVFIOPCIDriver()
        fake.failWrite.insert("/sys/bus/pci/drivers/vfio-pci/bind")
        let paths = VFIOBindPaths(
            devicesRoot: "/sys/bus/pci/devices",
            vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
            driversProbe: "/sys/bus/pci/drivers_probe",
        )
        let err = #expect(throws: BarkVisorError.self) {
            try VFIOBinder.bind(addresses: [address], paths: paths, sysfs: fake.sysfs)
        }
        if case let .forbidden(message) = err {
            #expect(message.contains("/sys/bus/pci/drivers/vfio-pci/bind"))
        } else {
            Issue.record("expected forbidden, got \(String(describing: err))")
        }
    }

    @Test func `qemu vfio args bind path uses sysfs without reading bind`() throws {
        let fake = FakeVFIOSysfs()
        let address = "0000:01:00.0"
        fake.addDevice(address, driver: "nvidia")
        fake.addVFIOPCIDriver()
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

    @Test func `partial iommu group bind unbinds members already taken`() throws {
        let fake = FakeVFIOSysfs()
        let gpu = "0000:01:00.0"
        let audio = "0000:01:00.1"
        fake.addDevice(gpu, driver: "nvidia")
        fake.addDevice(audio, driver: "snd_hda_intel")
        fake.addVFIOPCIDriver()
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
        fake.addDevice(gpu, driver: "nvidia")
        fake.addDevice(audio, driver: "snd_hda_intel")
        fake.addVFIOPCIDriver()
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
}

private final class FakeVFIOSysfs: @unchecked Sendable {
    var exists: Set<String> = []
    var driver: [String: String] = [:]
    var writes: [(path: String, text: String)] = []
    var readBindNode = false
    var skipBind: Set<String> = []
    var failWrite: Set<String> = []

    func addDevice(_ address: String, driver hostDriver: String? = nil) {
        let dir = "/sys/bus/pci/devices/\(address)"
        exists.insert(dir)
        exists.insert("\(dir)/iommu_group")
        exists.insert("\(dir)/driver_override")
        exists.insert("\(dir)/driver/unbind")
        if let hostDriver { driver[address] = hostDriver }
    }

    func addVFIOPCIDriver() {
        exists.insert("/sys/bus/pci/drivers/vfio-pci")
        exists.insert("/sys/bus/pci/drivers/vfio-pci/bind")
        exists.insert("/sys/bus/pci/drivers/vfio-pci/unbind")
        exists.insert("/sys/bus/pci/drivers_probe")
    }

    var sysfs: VFIOSysfs {
        VFIOSysfs(
            fileExists: { [weak self] path in self?.exists.contains(path) ?? false },
            currentDriver: { [weak self] address in self?.driver[address] },
            write: { [weak self] text, path in
                guard let self else { return }
                if self.failWrite.contains(path) {
                    throw CocoaError(.fileNoSuchFile)
                }
                self.writes.append((path, text))
                let addr = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasSuffix("/bind"), path.contains("vfio-pci") {
                    if self.skipBind.contains(addr) { return }
                    self.driver[addr] = "vfio-pci"
                }
                if path.hasSuffix("/unbind") {
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
