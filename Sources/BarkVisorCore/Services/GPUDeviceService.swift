import Foundation

/// PCI display device on the host, with IOMMU group and occupancy (PAS-275).
public struct HostGPUDevice: Codable, Equatable, Sendable {
    public let id: String
    public let pciAddress: String
    public let iommuGroup: String
    public let vendorId: String
    public let deviceId: String
    public let name: String
    public let driver: String?
    public let vfioBound: Bool
    public let inUseByHost: Bool
    public let attachable: Bool
    public let excludedReason: String?
    public let groupAddresses: [String]
    public let guestOllamaPath: String

    public init(
        pciAddress: String,
        iommuGroup: String,
        vendorId: String,
        deviceId: String,
        name: String,
        driver: String?,
        vfioBound: Bool,
        inUseByHost: Bool,
        attachable: Bool,
        excludedReason: String?,
        groupAddresses: [String],
        guestOllamaPath: String = GPUPassthroughService.guestOllamaPath,
    ) {
        let address = GPUPassthroughService.normalizePCIAddress(pciAddress)
        self.id = address
        self.pciAddress = address
        self.iommuGroup = iommuGroup
        self.vendorId = GPUPassthroughService.normalizeHexId(vendorId)
        self.deviceId = GPUPassthroughService.normalizeHexId(deviceId)
        self.name = name
        self.driver = driver
        self.vfioBound = vfioBound
        self.inUseByHost = inUseByHost
        self.attachable = attachable
        self.excludedReason = excludedReason
        self.groupAddresses = groupAddresses.map { GPUPassthroughService.normalizePCIAddress($0) }
        self.guestOllamaPath = guestOllamaPath
    }
}

public enum GPUDeviceService {
    /// List display-class PCI devices in IOMMU groups. Empty when IOMMU is off.
    public static func listDevices(
        hostOllamaReachable: Bool,
        fileManager: FileManager = .default,
    ) -> [HostGPUDevice] {
        #if os(Linux)
            listDevices(
                from: .linuxHost,
                hostOllamaReachable: hostOllamaReachable,
                fileManager: fileManager,
            )
        #else
            _ = hostOllamaReachable
            _ = fileManager
            return []
        #endif
    }

    public static func listDevices(
        from paths: VFIOProbePaths,
        hostOllamaReachable: Bool,
        fileManager: FileManager = .default,
    ) -> [HostGPUDevice] {
        let facts = VFIOProbe.collect(from: paths, fileManager: fileManager)
        guard facts.iommuEnabled else { return [] }
        let iommuReady = VFIOProbe.gpuPassthroughSupported(os: "Linux", facts: facts)
        return VFIOProbe.listDisplayDevices(from: paths, fileManager: fileManager).map { row in
            project(
                row,
                iommuReady: iommuReady,
                hostOllamaReachable: hostOllamaReachable,
            )
        }
    }

    public static func project(
        _ row: VFIODisplayDevice,
        iommuReady: Bool,
        hostOllamaReachable: Bool,
    ) -> HostGPUDevice {
        let vfioBound = row.driver == "vfio-pci"
        let hostDriver = GPUPassthroughService.isHostGPUDriver(row.driver)
        let inUseByHost = !vfioBound && hostDriver && hostOllamaReachable
        var attachable = iommuReady
        var reason: String?
        if !iommuReady {
            attachable = false
            reason = GPUPassthroughService.iommuNotReadyMessage
        } else if inUseByHost {
            attachable = false
            reason = GPUPassthroughService.hostGuestExclusiveMessage
        }
        return HostGPUDevice(
            pciAddress: row.pciAddress,
            iommuGroup: row.iommuGroup,
            vendorId: row.vendorId,
            deviceId: row.deviceId,
            name: GPUPassthroughService.displayName(
                vendorId: row.vendorId, deviceId: row.deviceId, driver: row.driver,
            ),
            driver: row.driver,
            vfioBound: vfioBound,
            inUseByHost: inUseByHost,
            attachable: attachable,
            excludedReason: reason,
            groupAddresses: row.groupAddresses,
        )
    }
}
