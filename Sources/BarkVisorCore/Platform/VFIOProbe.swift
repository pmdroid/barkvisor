import Foundation

/// Sysfs / device paths the IOMMU and vfio-pci probe reads (PAS-274).
public struct VFIOProbePaths: Sendable, Equatable {
    public var iommuGroups: String
    public var vfioPciDriver: String
    public var vfioModule: String
    public var vfioDevice: String
    public var kvmDevice: String

    public init(
        iommuGroups: String,
        vfioPciDriver: String,
        vfioModule: String,
        vfioDevice: String,
        kvmDevice: String,
    ) {
        self.iommuGroups = iommuGroups
        self.vfioPciDriver = vfioPciDriver
        self.vfioModule = vfioModule
        self.vfioDevice = vfioDevice
        self.kvmDevice = kvmDevice
    }

    public static let linuxHost = VFIOProbePaths(
        iommuGroups: "/sys/kernel/iommu_groups",
        vfioPciDriver: "/sys/bus/pci/drivers/vfio-pci",
        vfioModule: "/sys/module/vfio_pci",
        vfioDevice: "/dev/vfio/vfio",
        kvmDevice: "/dev/kvm",
    )
}

/// One display-class PCI function and the rest of its IOMMU group (PAS-275).
public struct VFIODisplayDevice: Sendable, Equatable {
    public var pciAddress: String
    public var iommuGroup: String
    public var vendorId: String
    public var deviceId: String
    public var driver: String?
    public var groupAddresses: [String]

    public init(
        pciAddress: String,
        iommuGroup: String,
        vendorId: String,
        deviceId: String,
        driver: String?,
        groupAddresses: [String],
    ) {
        self.pciAddress = pciAddress
        self.iommuGroup = iommuGroup
        self.vendorId = vendorId
        self.deviceId = deviceId
        self.driver = driver
        self.groupAddresses = groupAddresses
    }
}

/// Host facts for IOMMU groups, vfio-pci, and display-class PCI devices.
public struct VFIOHostFacts: Sendable, Equatable {
    public var iommuGroupCount: Int
    public var vfioPciPresent: Bool
    public var vfioDevicePresent: Bool
    public var kvmDevice: Bool
    public var gpuCount: Int

    public init(
        iommuGroupCount: Int = 0,
        vfioPciPresent: Bool = false,
        vfioDevicePresent: Bool = false,
        kvmDevice: Bool = false,
        gpuCount: Int = 0,
    ) {
        self.iommuGroupCount = iommuGroupCount
        self.vfioPciPresent = vfioPciPresent
        self.vfioDevicePresent = vfioDevicePresent
        self.kvmDevice = kvmDevice
        self.gpuCount = gpuCount
    }

    public var iommuEnabled: Bool {
        iommuGroupCount > 0
    }
    public var vfioPresent: Bool {
        vfioPciPresent || vfioDevicePresent
    }

    public var inventory: VFIOInventoryFacts {
        VFIOInventoryFacts(
            iommuGroupCount: iommuGroupCount,
            vfioPci: vfioPciPresent,
            vfioDevice: vfioDevicePresent,
            gpuCount: gpuCount,
        )
    }
}

/// Inventory projection of ``VFIOHostFacts`` (no KVM; that stays on `features.kvmDevice`).
public struct VFIOInventoryFacts: Codable, Sendable, Equatable {
    public var iommuGroupCount: Int
    public var vfioPci: Bool
    public var vfioDevice: Bool
    public var gpuCount: Int

    public init(
        iommuGroupCount: Int = 0,
        vfioPci: Bool = false,
        vfioDevice: Bool = false,
        gpuCount: Int = 0,
    ) {
        self.iommuGroupCount = iommuGroupCount
        self.vfioPci = vfioPci
        self.vfioDevice = vfioDevice
        self.gpuCount = gpuCount
    }

    public var iommuEnabled: Bool {
        iommuGroupCount > 0
    }
    public var vfioPresent: Bool {
        vfioPci || vfioDevice
    }

    public var hostFacts: VFIOHostFacts {
        VFIOHostFacts(
            iommuGroupCount: iommuGroupCount,
            vfioPciPresent: vfioPci,
            vfioDevicePresent: vfioDevice,
            kvmDevice: false,
            gpuCount: gpuCount,
        )
    }
}

/// Probe IOMMU groups, vfio-pci, and KVM. Does not bind devices or emit QEMU `-device vfio-pci`.
public enum VFIOProbe {
    /// Live host. Non-Linux is always empty (no macOS GPU passthrough).
    public static func live(fileManager: FileManager = .default) -> VFIOHostFacts {
        #if os(Linux)
            collect(from: .linuxHost, fileManager: fileManager)
        #else
            VFIOHostFacts()
        #endif
    }

    /// Read a sysfs-shaped tree. Used by tests with a temp directory.
    public static func collect(
        from paths: VFIOProbePaths,
        fileManager: FileManager = .default,
    ) -> VFIOHostFacts {
        let groups = iommuGroups(at: paths.iommuGroups, fileManager: fileManager)
        let vfioPci = fileManager.fileExists(atPath: paths.vfioPciDriver)
            || fileManager.fileExists(atPath: paths.vfioModule)
        let vfioDev = fileManager.fileExists(atPath: paths.vfioDevice)
        let kvm = fileManager.fileExists(atPath: paths.kvmDevice)
        let gpus = gpuCount(in: groups)
        return VFIOHostFacts(
            iommuGroupCount: groups.count,
            vfioPciPresent: vfioPci,
            vfioDevicePresent: vfioDev,
            kvmDevice: kvm,
            gpuCount: gpus,
        )
    }

    public static func vfioSupported(os: String, facts: VFIOHostFacts) -> Bool {
        isLinux(os) && facts.iommuEnabled && facts.vfioPresent
    }

    public static func gpuPassthroughSupported(os: String, facts: VFIOHostFacts) -> Bool {
        vfioSupported(os: os, facts: facts) && facts.kvmDevice && facts.gpuCount > 0
    }

    public static func vfioReason(os: String, facts: VFIOHostFacts) -> CapabilityReasonCode? {
        guard !vfioSupported(os: os, facts: facts) else { return nil }
        if !isLinux(os) { return .osUnsupported }
        if !facts.iommuEnabled { return .iommuMissing }
        return .vfioMissing
    }

    public static func gpuPassthroughReason(os: String, facts: VFIOHostFacts) -> CapabilityReasonCode? {
        guard !gpuPassthroughSupported(os: os, facts: facts) else { return nil }
        if !isLinux(os) { return .osUnsupported }
        if !facts.kvmDevice { return .kvmMissing }
        if !facts.iommuEnabled { return .iommuMissing }
        if !facts.vfioPresent { return .vfioMissing }
        return .gpuMissing
    }

    public static func listDisplayDevices(
        from paths: VFIOProbePaths,
        fileManager: FileManager = .default,
    ) -> [VFIODisplayDevice] {
        let groups = iommuGroups(at: paths.iommuGroups, fileManager: fileManager)
        var result: [VFIODisplayDevice] = []
        for group in groups {
            let addresses = group.deviceDirs.map(\.lastPathComponent).filter {
                GPUPassthroughService.isPCIAddress($0)
            }.sorted()
            for device in group.deviceDirs {
                let classURL = device.appendingPathComponent("class")
                guard let classRaw = try? String(contentsOf: classURL, encoding: .utf8),
                      isDisplayClass(classRaw)
                else { continue }
                let vendor = readHex(device.appendingPathComponent("vendor"))
                let product = readHex(device.appendingPathComponent("device"))
                let driver = readDriver(at: device, fileManager: fileManager)
                result.append(
                    VFIODisplayDevice(
                        pciAddress: GPUPassthroughService.normalizePCIAddress(device.lastPathComponent),
                        iommuGroup: group.id,
                        vendorId: vendor,
                        deviceId: product,
                        driver: driver,
                        groupAddresses: addresses.map { GPUPassthroughService.normalizePCIAddress($0) },
                    ),
                )
            }
        }
        return result.sorted { $0.pciAddress < $1.pciAddress }
    }

    public static func facts(
        from inventory: VFIOInventoryFacts,
        kvmDevice: Bool,
    ) -> VFIOHostFacts {
        VFIOHostFacts(
            iommuGroupCount: inventory.iommuGroupCount,
            vfioPciPresent: inventory.vfioPci,
            vfioDevicePresent: inventory.vfioDevice,
            kvmDevice: kvmDevice,
            gpuCount: inventory.gpuCount,
        )
    }

    // MARK: - Sysfs

    private struct IOMMUGroup {
        var id: String
        var deviceDirs: [URL]
    }

    private static func iommuGroups(at path: String, fileManager: FileManager) -> [IOMMUGroup] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { return [] }
        return names.compactMap { name in
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            let groupURL = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: groupURL.path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            let devicesRoot = groupURL.appendingPathComponent("devices", isDirectory: true)
            let deviceNames = (try? fileManager.contentsOfDirectory(atPath: devicesRoot.path)) ?? []
            let deviceDirs = deviceNames.map { devicesRoot.appendingPathComponent($0, isDirectory: true) }
            return IOMMUGroup(id: name, deviceDirs: deviceDirs)
        }
    }

    private static func gpuCount(in groups: [IOMMUGroup]) -> Int {
        var count = 0
        for group in groups {
            for device in group.deviceDirs {
                let classURL = device.appendingPathComponent("class")
                guard let raw = try? String(contentsOf: classURL, encoding: .utf8) else { continue }
                if isDisplayClass(raw) { count += 1 }
            }
        }
        return count
    }

    /// PCI base class 0x03 is display (VGA / 3D / other).
    public static func isDisplayClass(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        guard hex.count >= 2 else { return false }
        return hex.prefix(2) == "03"
    }

    private static func readHex(_ url: URL) -> String {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return GPUPassthroughService.normalizeHexId(raw)
    }

    private static func readDriver(at device: URL, fileManager: FileManager) -> String? {
        let link = device.appendingPathComponent("driver")
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        let name = URL(fileURLWithPath: dest).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func isLinux(_ os: String) -> Bool {
        os.caseInsensitiveCompare("Linux") == .orderedSame
    }
}
