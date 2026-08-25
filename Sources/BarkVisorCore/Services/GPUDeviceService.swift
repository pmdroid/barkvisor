import Foundation

/// PCI display device on the host, with IOMMU group and occupancy (PAS-275).
public struct HostGPUDevice: Codable, Equatable, Sendable {
    public let id: String
    public let pciAddress: String
    public let iommuGroup: String
    public let vendorId: String
    public let deviceId: String
    public let pciClass: String?
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
        pciClass: String? = nil,
    ) {
        let address = GPUPassthroughService.normalizePCIAddress(pciAddress)
        self.id = address
        self.pciAddress = address
        self.iommuGroup = iommuGroup
        self.vendorId = GPUPassthroughService.normalizeHexId(vendorId)
        self.deviceId = GPUPassthroughService.normalizeHexId(deviceId)
        self.pciClass = GPUPassthroughService.normalizePCIClass(pciClass)
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
        fileManager: FileManager = .default,
    ) -> [HostGPUDevice] {
        #if os(Linux)
            listDevices(from: .linuxHost, fileManager: fileManager)
        #else
            _ = fileManager
            return []
        #endif
    }

    public static func listDevices(
        from paths: VFIOProbePaths,
        fileManager: FileManager = .default,
    ) -> [HostGPUDevice] {
        let facts = VFIOProbe.collect(from: paths, fileManager: fileManager)
        guard facts.iommuEnabled else { return [] }
        let iommuReady = VFIOProbe.gpuPassthroughSupported(os: "Linux", facts: facts)
        return VFIOProbe.listDisplayDevices(from: paths, fileManager: fileManager).map { row in
            project(row, iommuReady: iommuReady)
        }
    }

    /// IOMMU-group PCI devices of any class. Empty on macOS.
    public static func listPCIDevices(
        fileManager: FileManager = .default,
    ) -> [HostGPUDevice] {
        #if os(Linux)
            let facts = VFIOProbe.collect(from: .linuxHost, fileManager: fileManager)
            guard facts.iommuEnabled else { return [] }
            let iommuReady = VFIOProbe.vfioSupported(os: "Linux", facts: facts) && facts.kvmDevice
            let rows = VFIOProbe.listPCIDevices(from: .linuxHost, fileManager: fileManager)
            let network = Set(rows.filter { VFIOProbe.isNetworkClass($0.pciClass) }.map(\.pciAddress))
            let safety = PCIHostSafety.live(
                networkPCIAddresses: network, fileManager: fileManager,
            )
            let occupied = hostOccupiedAddresses(rows)
            return rows.map {
                project($0, iommuReady: iommuReady, safety: safety, groupHostOccupied: occupied)
            }
        #else
            _ = fileManager
            return []
        #endif
    }

    public static func listPCIDevices(
        from paths: VFIOProbePaths,
        fileManager: FileManager = .default,
        safety: PCIHostSafety = .empty,
    ) -> [HostGPUDevice] {
        let facts = VFIOProbe.collect(from: paths, fileManager: fileManager)
        guard facts.iommuEnabled else { return [] }
        let iommuReady = VFIOProbe.vfioSupported(os: "Linux", facts: facts) && facts.kvmDevice
        let rows = VFIOProbe.listPCIDevices(from: paths, fileManager: fileManager)
        let occupied = hostOccupiedAddresses(rows)
        return rows.map {
            project($0, iommuReady: iommuReady, safety: safety, groupHostOccupied: occupied)
        }
    }

    public static func hostOccupiedAddresses(_ rows: [VFIODisplayDevice]) -> Set<String> {
        var occupied = Set<String>()
        for row in rows {
            let display = VFIOProbe.isDisplayClass(row.pciClass)
            let vfioBound = row.driver == "vfio-pci"
            guard display, !vfioBound, GPUPassthroughService.isHostGPUDriver(row.driver) else {
                continue
            }
            occupied.insert(GPUPassthroughService.normalizePCIAddress(row.pciAddress))
            occupied.formUnion(
                row.groupAddresses.map { GPUPassthroughService.normalizePCIAddress($0) },
            )
        }
        return occupied
    }

    public static func project(
        _ row: VFIODisplayDevice,
        iommuReady: Bool,
        safety: PCIHostSafety = .empty,
        groupHostOccupied: Set<String> = [],
    ) -> HostGPUDevice {
        let vfioBound = row.driver == "vfio-pci"
        let display = VFIOProbe.isDisplayClass(row.pciClass)
        let inUseByHost =
            groupHostOccupied.contains(GPUPassthroughService.normalizePCIAddress(row.pciAddress))
                || (display && !vfioBound && GPUPassthroughService.isHostGPUDriver(row.driver))
        var attachable = iommuReady
        var reason: String?
        if !iommuReady {
            attachable = false
            reason = display
                ? GPUPassthroughService.iommuNotReadyMessage
                : GPUPassthroughService.pciPassthroughNotReadyMessage
        } else if VFIOProbe.isBridgeClass(row.pciClass) {
            attachable = false
            reason = GPUPassthroughService.pciBridgeExclusionReason
        } else if let blocked = safety.blocks(row.pciAddress, groupAddresses: row.groupAddresses) {
            attachable = false
            reason = blocked
        } else if inUseByHost {
            reason = GPUPassthroughService.hostGuestExclusiveMessage
        }
        return HostGPUDevice(
            pciAddress: row.pciAddress,
            iommuGroup: row.iommuGroup,
            vendorId: row.vendorId,
            deviceId: row.deviceId,
            name: GPUPassthroughService.pciDeviceName(
                vendorId: row.vendorId,
                deviceId: row.deviceId,
                pciClass: row.pciClass,
                driver: row.driver,
            ),
            driver: row.driver,
            vfioBound: vfioBound,
            inUseByHost: inUseByHost,
            attachable: attachable,
            excludedReason: reason,
            groupAddresses: row.groupAddresses,
            pciClass: row.pciClass,
        )
    }
}
