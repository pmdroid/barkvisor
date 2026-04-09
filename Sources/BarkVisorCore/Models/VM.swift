import Foundation
import GRDB

public struct USBPassthroughDevice: Codable, Equatable, Sendable {
    public let vendorId: String
    public let productId: String
    public let label: String?

    public init(vendorId: String, productId: String, label: String? = nil) {
        self.vendorId = vendorId
        self.productId = productId
        self.label = label
    }
}

public struct VM: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "vms"

    public var id: String
    public var name: String
    public var vmType: String
    public var state: String
    public var cpuCount: Int
    public var memoryMb: Int
    public var bootDiskId: String
    public var isoId: String? // Deprecated: use isoIds
    public var isoIds: String? // JSON-encoded [String]
    public var networkId: String?
    public var cloudInitPath: String?
    public var vncPort: Int?
    public var description: String?
    public var bootOrder: String?
    public var displayResolution: String?
    public var additionalDiskIds: String?
    public var uefi: Bool
    public var tpmEnabled: Bool
    public var macAddress: String?
    public var sharedPaths: String? // JSON-encoded [String]
    public var portForwards: String? // JSON-encoded [PortForwardRule]
    public var usbDevices: String? // JSON-encoded [USBPassthroughDevice]
    public var autoCreated: Bool
    public var pendingChanges: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        vmType: String,
        state: String,
        cpuCount: Int,
        memoryMb: Int,
        bootDiskId: String,
        isoId: String? = nil,
        isoIds: String? = nil,
        networkId: String?,
        cloudInitPath: String?,
        vncPort: Int?,
        description: String?,
        bootOrder: String?,
        displayResolution: String?,
        additionalDiskIds: String?,
        uefi: Bool,
        tpmEnabled: Bool,
        macAddress: String?,
        sharedPaths: String?,
        portForwards: String?,
        usbDevices: String? = nil,
        autoCreated: Bool,
        pendingChanges: Bool,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.name = name
        self.vmType = vmType
        self.state = state
        self.cpuCount = cpuCount
        self.memoryMb = memoryMb
        self.bootDiskId = bootDiskId
        self.isoId = isoId
        self.isoIds = isoIds
        self.networkId = networkId
        self.cloudInitPath = cloudInitPath
        self.vncPort = vncPort
        self.description = description
        self.bootOrder = bootOrder
        self.displayResolution = displayResolution
        self.additionalDiskIds = additionalDiskIds
        self.uefi = uefi
        self.tpmEnabled = tpmEnabled
        self.macAddress = macAddress
        self.sharedPaths = sharedPaths
        self.portForwards = portForwards
        self.usbDevices = usbDevices
        self.autoCreated = autoCreated
        self.pendingChanges = pendingChanges
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
