import Foundation

// MARK: - Parameter Types

public struct CreateVMParams: Sendable {
    public let name: String
    public let vmType: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeGB: Int?
    public let isoId: String?
    public let cloudImageId: String?
    public let cloudInit: CloudInitConfig?
    public let networkId: String?
    public let existingDiskId: String?
    public let sharedPaths: [String]?
    public let portForwards: [PortForwardRule]?
    public let usbDevices: [USBPassthroughDevice]?
    public let description: String?
    public let bootOrder: String?
    public let displayResolution: String?
    public let uefi: Bool?
    public let tpmEnabled: Bool?

    public init(
        name: String,
        vmType: String,
        cpuCount: Int,
        memoryMB: Int,
        diskSizeGB: Int? = nil,
        isoId: String? = nil,
        cloudImageId: String? = nil,
        cloudInit: CloudInitConfig? = nil,
        networkId: String? = nil,
        existingDiskId: String? = nil,
        sharedPaths: [String]? = nil,
        portForwards: [PortForwardRule]? = nil,
        usbDevices: [USBPassthroughDevice]? = nil,
        description: String? = nil,
        bootOrder: String? = nil,
        displayResolution: String? = nil,
        uefi: Bool? = nil,
        tpmEnabled: Bool? = nil,
    ) {
        self.name = name
        self.vmType = vmType
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.isoId = isoId
        self.cloudImageId = cloudImageId
        self.cloudInit = cloudInit
        self.networkId = networkId
        self.existingDiskId = existingDiskId
        self.sharedPaths = sharedPaths
        self.portForwards = portForwards
        self.usbDevices = usbDevices
        self.description = description
        self.bootOrder = bootOrder
        self.displayResolution = displayResolution
        self.uefi = uefi
        self.tpmEnabled = tpmEnabled
    }
}

public struct UpdateVMParams: Sendable {
    public let name: String?
    public let cpuCount: Int?
    public let memoryMB: Int?
    public let networkId: String?
    public let portForwards: [PortForwardRule]?
    public let usbDevices: [USBPassthroughDevice]?
    public let description: String?
    public let bootOrder: String?
    public let displayResolution: String?
    public let additionalDiskIds: [String]?
    public let sharedPaths: [String]?
    public let uefi: Bool?
    public let tpmEnabled: Bool?

    public init(
        name: String? = nil,
        cpuCount: Int? = nil,
        memoryMB: Int? = nil,
        networkId: String? = nil,
        portForwards: [PortForwardRule]? = nil,
        usbDevices: [USBPassthroughDevice]? = nil,
        description: String? = nil,
        bootOrder: String? = nil,
        displayResolution: String? = nil,
        additionalDiskIds: [String]? = nil,
        sharedPaths: [String]? = nil,
        uefi: Bool? = nil,
        tpmEnabled: Bool? = nil,
    ) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.networkId = networkId
        self.portForwards = portForwards
        self.usbDevices = usbDevices
        self.description = description
        self.bootOrder = bootOrder
        self.displayResolution = displayResolution
        self.additionalDiskIds = additionalDiskIds
        self.sharedPaths = sharedPaths
        self.uefi = uefi
        self.tpmEnabled = tpmEnabled
    }
}

public enum CreateVMResult {
    case created(VM)
    case provisioning(taskID: String, vm: VM)
}
