import Foundation

/// Versioned host inventory snapshot (schemaVersion 1).
///
/// Single source of truth for "what is this machine?" — projected into
/// `/api/system/capabilities`, diagnostics, and later `/api/agent/inventory`.
///
/// **Boundary:** one BarkVisor process ↔ one host ↔ one inventory.
public struct HostInventory: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let displayName: String
    public let agent: AgentInfo
    public let platform: PlatformInfo
    public let resources: ResourcesInfo
    public let storage: [StorageEntry]
    public let networking: NetworkingInfo
    public let virtualization: VirtualizationInfo
    public let guestTypes: [GuestTypeSnapshot]
    public let collectedAt: String

    public init(
        schemaVersion: Int = 1,
        displayName: String,
        agent: AgentInfo,
        platform: PlatformInfo,
        resources: ResourcesInfo,
        storage: [StorageEntry],
        networking: NetworkingInfo,
        virtualization: VirtualizationInfo,
        guestTypes: [GuestTypeSnapshot],
        collectedAt: String,
    ) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.agent = agent
        self.platform = platform
        self.resources = resources
        self.storage = storage
        self.networking = networking
        self.virtualization = virtualization
        self.guestTypes = guestTypes
        self.collectedAt = collectedAt
    }
}

public struct AgentInfo: Codable, Sendable, Equatable {
    /// `colocal` = agent role of the full BarkVisor daemon (not a separate binary).
    public let role: String
    public let version: String
    public let apiVersion: Int

    public init(role: String = "colocal", version: String, apiVersion: Int = 1) {
        self.role = role
        self.version = version
        self.apiVersion = apiVersion
    }
}

public struct PlatformInfo: Codable, Sendable, Equatable {
    public let os: String
    public let osVersion: String
    public let arch: String
    public let hostname: String

    public init(os: String, osVersion: String, arch: String, hostname: String) {
        self.os = os
        self.osVersion = osVersion
        self.arch = arch
        self.hostname = hostname
    }
}

public struct ResourcesInfo: Codable, Sendable, Equatable {
    public let cpuCount: Int
    public let memoryTotalMB: Int
    public let memoryUsedMB: Int
    public let cpuLoadPercent: Double

    public init(cpuCount: Int, memoryTotalMB: Int, memoryUsedMB: Int, cpuLoadPercent: Double) {
        self.cpuCount = cpuCount
        self.memoryTotalMB = memoryTotalMB
        self.memoryUsedMB = memoryUsedMB
        self.cpuLoadPercent = cpuLoadPercent
    }
}

public struct StorageEntry: Codable, Sendable, Equatable {
    public let path: String
    public let totalBytes: UInt64?
    public let freeBytes: UInt64?
    public let kind: String

    public init(path: String, totalBytes: UInt64?, freeBytes: UInt64?, kind: String) {
        self.path = path
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.kind = kind
    }
}

public struct NetworkingInfo: Codable, Sendable, Equatable {
    public let interfaces: [NetworkInterfaceInfo]

    public init(interfaces: [NetworkInterfaceInfo]) {
        self.interfaces = interfaces
    }
}

public struct NetworkInterfaceInfo: Codable, Sendable, Equatable {
    public let name: String
    public let displayName: String
    public let ipv4: [String]
    public let exists: Bool

    public init(name: String, displayName: String, ipv4: [String], exists: Bool = true) {
        self.name = name
        self.displayName = displayName
        self.ipv4 = ipv4
        self.exists = exists
    }
}

public struct VirtualizationInfo: Codable, Sendable, Equatable {
    public let accelerator: String
    public let qemuCPUModel: String
    public let defaultGuestArch: String
    public let features: VirtualizationFeatures

    public init(
        accelerator: String,
        qemuCPUModel: String,
        defaultGuestArch: String,
        features: VirtualizationFeatures,
    ) {
        self.accelerator = accelerator
        self.qemuCPUModel = qemuCPUModel
        self.defaultGuestArch = defaultGuestArch
        self.features = features
    }
}

public struct VirtualizationFeatures: Codable, Sendable, Equatable {
    public let bridgedNetworking: Bool
    public let managedBridgeDaemon: Bool
    public let usbPassthrough: Bool
    public let inAppUpdate: Bool
    public let kvmDevice: Bool
    public let qemuBridgeHelper: Bool

    public init(
        bridgedNetworking: Bool,
        managedBridgeDaemon: Bool,
        usbPassthrough: Bool,
        inAppUpdate: Bool,
        kvmDevice: Bool,
        qemuBridgeHelper: Bool,
    ) {
        self.bridgedNetworking = bridgedNetworking
        self.managedBridgeDaemon = managedBridgeDaemon
        self.usbPassthrough = usbPassthrough
        self.inAppUpdate = inAppUpdate
        self.kvmDevice = kvmDevice
        self.qemuBridgeHelper = qemuBridgeHelper
    }
}

/// Guest profile snapshot for inventory (stable persisted IDs).
public struct GuestTypeSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let arch: String
    public let machine: String
    public let osFamily: String
    public let qemuBinary: String

    public init(id: String, arch: String, machine: String, osFamily: String, qemuBinary: String) {
        self.id = id
        self.arch = arch
        self.machine = machine
        self.osFamily = osFamily
        self.qemuBinary = qemuBinary
    }
}
