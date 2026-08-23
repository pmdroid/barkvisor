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
    /// Optional HTTP/TCP guest probes (PAS-65). Omitted = process-state health only.
    public var health: WorkloadHealthSpec?
    /// `house` | `agent`. Omitted = house (PAS-268).
    public var workloadClass: String?

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
        health: WorkloadHealthSpec? = nil,
        workloadClass: String? = nil,
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
        self.health = health
        self.workloadClass = workloadClass
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
    public var serialNumber: String?
    public var deviceId: String?

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

public struct WorkloadDisplay: Codable, Equatable, Sendable {
    public var resolution: String?

    public init(resolution: String? = nil) {
        self.resolution = resolution
    }
}

/// Partial resource overlay. Omitted fields keep the portable spec value.
public struct WorkloadResourcesOverlay: Codable, Equatable, Sendable {
    public var cpu: Int?
    public var memoryMb: Int?

    public init(cpu: Int? = nil, memoryMb: Int? = nil) {
        self.cpu = cpu
        self.memoryMb = memoryMb
    }
}

/// Partial firmware overlay. Omitted fields keep the portable spec value.
public struct WorkloadFirmwareOverlay: Codable, Equatable, Sendable {
    public var uefi: Bool?
    public var tpm: Bool?

    public init(uefi: Bool? = nil, tpm: Bool? = nil) {
        self.uefi = uefi
        self.tpm = tpm
    }
}

/// Platform-specific spec overlay (PAS-41). Deep-merged onto `spec` for the
/// current host OS at validate/launch. Raw QEMU argv is rejected.
public struct WorkloadSpecOverlay: Equatable, Sendable {
    public var resources: WorkloadResourcesOverlay?
    public var arch: String?
    public var guestType: String?
    public var osFamily: String?
    public var machine: String?
    public var firmware: WorkloadFirmwareOverlay?
    public var bootOrder: String?
    public var display: WorkloadDisplay?
    public var accelerator: String?
    public var hugepages: Bool?

    public init(
        resources: WorkloadResourcesOverlay? = nil,
        arch: String? = nil,
        guestType: String? = nil,
        osFamily: String? = nil,
        machine: String? = nil,
        firmware: WorkloadFirmwareOverlay? = nil,
        bootOrder: String? = nil,
        display: WorkloadDisplay? = nil,
        accelerator: String? = nil,
        hugepages: Bool? = nil,
    ) {
        self.resources = resources
        self.arch = arch
        self.guestType = guestType
        self.osFamily = osFamily
        self.machine = machine
        self.firmware = firmware
        self.bootOrder = bootOrder
        self.display = display
        self.accelerator = accelerator
        self.hugepages = hugepages
    }

    public var isEmpty: Bool {
        resources == nil && arch == nil && guestType == nil && osFamily == nil
            && machine == nil && firmware == nil && bootOrder == nil
            && display == nil && accelerator == nil && hugepages == nil
    }
}

extension WorkloadSpecOverlay: Codable {
    /// Keys that would inject raw QEMU arguments. Never accepted in v1.
    public static let argvKeys: Set<String> = [
        "argv", "args", "qemuArgs", "qemuArgv", "extraArgs", "extraQemuArgs",
        "rawArgs", "cmdline", "qemu", "qemuArg", "additionalArgs", "extraQemu",
    ]

    /// Attachment fields stay on the portable spec in v1 (no host-local apply).
    public static let deferredKeys: Set<String> = [
        "disks", "networks", "usb", "sharedPaths", "cloudInit",
    ]

    public static let forbiddenKeys: Set<String> = argvKeys.union(deferredKeys)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case resources, arch, guestType, osFamily, machine
        case firmware, bootOrder, display, accelerator, hugepages
    }

    public init(from decoder: Decoder) throws {
        try WorkloadOverrideJSON.rejectUnknownKeys(
            decoder: decoder,
            known: Set(CodingKeys.allCases.map(\.stringValue)),
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resources = try container.decodeIfPresent(WorkloadResourcesOverlay.self, forKey: .resources)
        arch = try container.decodeIfPresent(String.self, forKey: .arch)
        guestType = try container.decodeIfPresent(String.self, forKey: .guestType)
        osFamily = try container.decodeIfPresent(String.self, forKey: .osFamily)
        machine = try container.decodeIfPresent(String.self, forKey: .machine)
        firmware = try container.decodeIfPresent(WorkloadFirmwareOverlay.self, forKey: .firmware)
        bootOrder = try container.decodeIfPresent(String.self, forKey: .bootOrder)
        display = try container.decodeIfPresent(WorkloadDisplay.self, forKey: .display)
        accelerator = try container.decodeIfPresent(String.self, forKey: .accelerator)
        hugepages = try container.decodeIfPresent(Bool.self, forKey: .hugepages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(resources, forKey: .resources)
        try container.encodeIfPresent(arch, forKey: .arch)
        try container.encodeIfPresent(guestType, forKey: .guestType)
        try container.encodeIfPresent(osFamily, forKey: .osFamily)
        try container.encodeIfPresent(machine, forKey: .machine)
        try container.encodeIfPresent(firmware, forKey: .firmware)
        try container.encodeIfPresent(bootOrder, forKey: .bootOrder)
        try container.encodeIfPresent(display, forKey: .display)
        try container.encodeIfPresent(accelerator, forKey: .accelerator)
        try container.encodeIfPresent(hugepages, forKey: .hugepages)
    }
}

/// Platform-specific override bags. Deep-merged at apply/launch for the host OS.
public struct WorkloadOverrides: Codable, Equatable, Sendable {
    public var linux: WorkloadSpecOverlay?
    public var macos: WorkloadSpecOverlay?

    public init(linux: WorkloadSpecOverlay? = nil, macos: WorkloadSpecOverlay? = nil) {
        self.linux = linux
        self.macos = macos
    }

    public var isEmpty: Bool {
        (linux == nil || linux?.isEmpty == true) && (macos == nil || macos?.isEmpty == true)
    }
}

enum WorkloadOverrideJSON {
    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func rejectUnknownKeys(decoder: Decoder, known: Set<String>) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in container.allKeys {
            let name = key.stringValue
            let path = (decoder.codingPath.map(\.stringValue) + [name]).joined(separator: ".")
            if WorkloadSpecOverlay.argvKeys.contains(name) {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(path) is not allowed (raw QEMU argv is not supported)",
                )
            }
            if WorkloadSpecOverlay.deferredKeys.contains(name) {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(path) is not supported in v1",
                )
            }
            if !known.contains(name) {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(path) is not a valid override",
                )
            }
        }
    }
}

/// Runtime projection returned next to `WorkloadSpec` (not part of the document).
public struct VMRuntimeStatus: Codable, Equatable, Sendable {
    public var state: VMState
    public var pendingChanges: Bool
    public var generation: Int
    public var createdAt: String
    public var updatedAt: String
    public var health: WorkloadHealth
    public var healthError: String?
    /// Effective QEMU backend for this workload (PAS-73).
    public var backend: VMRuntimeBackend
    /// PAS-258: start after Device boot. Host-only, not part of the portable spec.
    public var startOnBoot: Bool

    public init(
        state: VMState,
        pendingChanges: Bool,
        generation: Int,
        createdAt: String,
        updatedAt: String,
        health: WorkloadHealth,
        healthError: String? = nil,
        backend: VMRuntimeBackend,
        startOnBoot: Bool = false,
    ) {
        self.state = state
        self.pendingChanges = pendingChanges
        self.generation = generation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.health = health
        self.healthError = healthError
        self.backend = backend
        self.startOnBoot = startOnBoot
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

    static func encodeHealth(_ spec: WorkloadHealthSpec) -> String? {
        guard let data = try? encoder.encode(spec) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
