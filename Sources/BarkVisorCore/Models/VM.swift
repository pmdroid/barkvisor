import Foundation
import GRDB

public struct USBPassthroughDevice: Codable, Equatable, Sendable {
    public let vendorId: String
    public let productId: String
    public let label: String?
    public let serialNumber: String?
    public let deviceId: String?

    public init(
        vendorId: String,
        productId: String,
        label: String? = nil,
        serialNumber: String? = nil,
        deviceId: String? = nil,
    ) {
        let ref = USBDeviceIdentity.make(
            vendorId: vendorId,
            productId: productId,
            serial: serialNumber,
        )
        self.vendorId = ref.vendorId
        self.productId = ref.productId
        self.label = label
        self.serialNumber = USBDeviceIdentity.normalizedSerial(serialNumber)
        self.deviceId = deviceId ?? (ref.serial != nil ? ref.id : nil)
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
    public var isoIds: String? // JSON-encoded [String]
    public var networkId: String?
    public var cloudInitPath: String?
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
    /// Stored WorkloadSpec document. Columns remain source of truth; the
    /// pipeline reads this as `EffectiveWorkload.storedDocument`.
    public var specJson: String?
    /// Portable `overrides.linux` / `overrides.macos` bags (PAS-41).
    public var overridesJson: String?
    /// PAS-65 HTTP/TCP health-check config (Linear `spec.health`).
    public var healthJson: String?
    public var specGeneration: Int
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
        isoIds: String? = nil,
        networkId: String?,
        cloudInitPath: String?,
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
        specJson: String? = nil,
        overridesJson: String? = nil,
        healthJson: String? = nil,
        specGeneration: Int = 1,
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
        self.isoIds = isoIds
        self.networkId = networkId
        self.cloudInitPath = cloudInitPath
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
        self.specJson = specJson
        self.overridesJson = overridesJson
        self.healthJson = healthJson
        self.specGeneration = specGeneration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Refresh stored `specJson` from columns. Bump generation on user-facing writes.
    public mutating func syncSpecProjection(bumpGeneration: Bool = true) {
        if bumpGeneration {
            specGeneration += 1
        }
        specJson = WorkloadSpecJSON.encode(WorkloadSpecProjector.fromVM(self))
    }
}
