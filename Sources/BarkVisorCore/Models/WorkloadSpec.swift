import Foundation

/// Portable BarkVisor VM document (`apiVersion: barkvisor.dev/v1`).
///
/// Host-only runtime fields (`state`, `pendingChanges`, timestamps) live on
/// `VMRuntimeStatus`, not here. Column mapping: `WorkloadSpecProjector`.
public struct WorkloadSpec: Codable, Equatable, Sendable {
    public static let currentAPIVersion = "barkvisor.dev/v1"
    public static let kindVirtualMachine = "VirtualMachine"

    public var apiVersion: String
    public var kind: String
    public var metadata: WorkloadMetadata
    public var spec: WorkloadSpecBody
    public var overrides: WorkloadOverrides?

    public init(
        apiVersion: String = WorkloadSpec.currentAPIVersion,
        kind: String = WorkloadSpec.kindVirtualMachine,
        metadata: WorkloadMetadata,
        spec: WorkloadSpecBody,
        overrides: WorkloadOverrides? = nil,
    ) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.metadata = metadata
        self.spec = spec
        self.overrides = overrides
    }
}

public struct WorkloadMetadata: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var description: String?
    public var labels: [String: String]?

    public init(
        id: String? = nil,
        name: String,
        description: String? = nil,
        labels: [String: String]? = nil,
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.labels = labels
    }
}

public struct WorkloadSpecBody: Codable, Equatable, Sendable {
    public var resources: WorkloadResources
    /// QEMU guest arch (`aarch64` / `x86_64`). Optional on apply — defaulted from host.
    public var arch: String?
    /// BarkVisor guest profile id (`linux-arm64`, …). Native field for round-trip.
    public var guestType: String?
    public var osFamily: String?
    public var machine: String?
    public var firmware: WorkloadFirmware?
    public var bootOrder: String?
    public var disks: [WorkloadDisk]
    public var networks: [WorkloadNetwork]
    public var cloudInit: WorkloadCloudInit?
    public var usb: [WorkloadUSBDevice]
    public var display: WorkloadDisplay?
    /// Host bind-mounts (virtio-9p). Portable in the native spec; host paths stay host-local.
    public var sharedPaths: [String]?

    public init(
        resources: WorkloadResources,
        arch: String? = nil,
        guestType: String? = nil,
        osFamily: String? = nil,
        machine: String? = nil,
        firmware: WorkloadFirmware? = nil,
        bootOrder: String? = nil,
        disks: [WorkloadDisk] = [],
        networks: [WorkloadNetwork] = [],
        cloudInit: WorkloadCloudInit? = nil,
        usb: [WorkloadUSBDevice] = [],
        display: WorkloadDisplay? = nil,
        sharedPaths: [String]? = nil,
    ) {
        self.resources = resources
        self.arch = arch
        self.guestType = guestType
        self.osFamily = osFamily
        self.machine = machine
        self.firmware = firmware
        self.bootOrder = bootOrder
        self.disks = disks
        self.networks = networks
        self.cloudInit = cloudInit
        self.usb = usb
        self.display = display
        self.sharedPaths = sharedPaths
    }
}

public struct WorkloadResources: Codable, Equatable, Sendable {
    public var cpu: Int
    public var memoryMb: Int

    public init(cpu: Int, memoryMb: Int) {
        self.cpu = cpu
        self.memoryMb = memoryMb
    }
}

public struct WorkloadFirmware: Codable, Equatable, Sendable {
    public var uefi: Bool
    public var tpm: Bool

    public init(uefi: Bool, tpm: Bool) {
        self.uefi = uefi
        self.tpm = tpm
    }
}

public struct WorkloadDisk: Codable, Equatable, Sendable {
    /// `boot` | `data` | `cdrom`
    public var role: String
    public var diskId: String?
    public var imageId: String?
    public var bus: String?

    public init(role: String, diskId: String? = nil, imageId: String? = nil, bus: String? = nil) {
        self.role = role
        self.diskId = diskId
        self.imageId = imageId
        self.bus = bus
    }
}

public struct WorkloadNetwork: Codable, Equatable, Sendable {
    public var mode: String?
    public var networkId: String?
    public var mac: String?
    public var portForwards: [WorkloadPortForward]

    public init(
        mode: String? = nil,
        networkId: String? = nil,
        mac: String? = nil,
        portForwards: [WorkloadPortForward] = [],
    ) {
        self.mode = mode
        self.networkId = networkId
        self.mac = mac
        self.portForwards = portForwards
    }
}

public struct WorkloadPortForward: Codable, Equatable, Sendable {
    public var hostPort: Int
    public var guestPort: Int
    public var proto: String

    public init(hostPort: Int, guestPort: Int, proto: String) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.proto = proto
    }
}

public struct WorkloadCloudInit: Codable, Equatable, Sendable {
    public var userDataRef: String?
    public var inline: String?

    public init(userDataRef: String? = nil, inline: String? = nil) {
        self.userDataRef = userDataRef
        self.inline = inline
    }
}

public struct WorkloadUSBDevice: Codable, Equatable, Sendable {
    public var vendorId: String
    public var productId: String
    public var label: String?

    public init(vendorId: String, productId: String, label: String? = nil) {
        self.vendorId = vendorId
        self.productId = productId
        self.label = label
    }
}

public struct WorkloadDisplay: Codable, Equatable, Sendable {
    public var resolution: String?

    public init(resolution: String? = nil) {
        self.resolution = resolution
    }
}

/// Platform-specific override bags. Empty in Wave 0; reserved for PAS-41.
public struct WorkloadOverrides: Codable, Equatable, Sendable {
    public var linux: [String: String]?
    public var macos: [String: String]?

    public init(linux: [String: String]? = nil, macos: [String: String]? = nil) {
        self.linux = linux
        self.macos = macos
    }
}

/// Runtime projection returned next to `WorkloadSpec` (not part of the document).
public struct VMRuntimeStatus: Codable, Equatable, Sendable {
    public var state: VMState
    public var pendingChanges: Bool
    public var generation: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        state: VMState,
        pendingChanges: Bool,
        generation: Int,
        createdAt: String,
        updatedAt: String,
    ) {
        self.state = state
        self.pendingChanges = pendingChanges
        self.generation = generation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum WorkloadSpecJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func encode(_ spec: WorkloadSpec) -> String? {
        guard let data = try? encoder.encode(spec) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> WorkloadSpec? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(WorkloadSpec.self, from: data)
    }
}
