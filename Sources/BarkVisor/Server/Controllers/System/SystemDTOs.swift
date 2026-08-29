import BarkVisorCore
import Vapor

struct HostInterface: Content {
    let name: String
    let displayName: String
    let ipAddress: String
    let bridgeStatus: String? // "active", "installed", or "not_configured"
}

struct BridgeInfo: Content {
    let interface: String
    let socketPath: String?
    let plistExists: Bool
    let daemonRunning: Bool
    let status: String // "active", "installed", "not_configured"
}

struct BridgeRequest: Content {
    let interface: String
}

struct BridgeActionResponse: Content {
    let success: Bool
    let message: String?
}

struct OnboardingStatus: Content {
    let complete: Bool
}

struct AppInfoResponse: Content {
    let version: String
    let platform: String
    let hostArch: String
    let accelerator: String
    let processUptimeSeconds: Int
    let displayName: String
    let licenses: [LicenseEntry]
}

struct LicenseEntry: Content {
    let name: String
    let license: String
    let url: String
    let description: String
}

struct BrowseEntry: Content {
    let name: String
    let path: String
    let isDirectory: Bool
}

struct HostBlockDeviceResponse: Content {
    let path: String
    let name: String
    let sizeBytes: Int64
    let model: String?
    let attachable: Bool
    let excludedReason: String?
}

struct VirtioWinStatusResponse: Content {
    let available: Bool
    let imageId: String?
}

struct VirtioWinDownloadResponse: Content {
    let imageId: String
}

/// Supported guest type for create UI / validation (stable persisted IDs).
struct GuestTypeInfo: Content {
    let id: String
    let arch: String
    let machine: String
    let osFamily: String
    let qemuBinary: String
}

/// Platform feature flags for UI gating (bridged networking, USB, appliance updates).
struct SystemCapabilitiesResponse: Content {
    let platform: String
    /// VMs may use bridged networking (Linux host bridge or macOS socket_vmnet).
    let supportsBridgedNetworking: Bool
    /// Install/start/stop socket_vmnet via the root Device daemon (macOS).
    let supportsManagedBridgeDaemon: Bool
    /// Linux Bridge setup shows host-bridge install guidance (no mutation).
    let supportsHostBridgeManagement: Bool
    let supportsUSBPassthrough: Bool
    let supportsInAppUpdate: Bool
    /// Linux IOMMU + vfio-pci + KVM + a GPU in a group. Not QEMU vfio-pci attach (PAS-274).
    let supportsGPUPassthrough: Bool
    /// IOMMU groups exist and vfio-pci (or `/dev/vfio/vfio`) is present.
    let supportsVFIO: Bool
    let accelerator: String
    let hostArch: String
    /// Online logical CPU count on the host (max assignable vCPUs per VM).
    let hostCpuCount: Int
    let maxMemoryMB: Int
    /// Guest profiles this host can run natively (host-arch filtered).
    let guestTypes: [GuestTypeInfo]
    /// Per-feature support + reason/remediation (PAS-37 / PAS-94). Booleans stay for older clients.
    let details: [CapabilityDetail]
    /// Inventory schema the booleans/details were projected from.
    let inventorySchemaVersion: Int
    /// Architectures this host can run natively (Wave 0: host arch only).
    /// Clients must not infer runnable arches from `guestTypes`.
    let runnableArches: [String]
    /// Per-mode support (PAS-57 / PAS-67): `nat`, `bridged`, `isolated`.
    let networkModes: [NetworkModeCapability]
}

extension CapabilityDetail: Content {}
extension CapabilityCode: Content {}
extension NetworkModeCapability: Content {}
extension HostBridgeReadiness: Content {}
extension HostBridgeSnapshot: Content {}
extension HostBridgeRemediation: Content {}
extension DoctorReport: Content {}
extension DoctorCheck: Content {}
extension DoctorCheckStatus: Content {}

struct HostGPUDeviceResponse: Content {
    let id: String
    let pciAddress: String
    let iommuGroup: String
    let vendorId: String
    let deviceId: String
    let pciClass: String?
    let name: String
    let driver: String?
    let vfioBound: Bool
    let inUseByHost: Bool
    let attachable: Bool
    let excludedReason: String?
    let groupAddresses: [String]
    let guestOllamaPath: String
    let busy: Bool
    let attachedToVmId: String?
    let claimedByVMId: String?
    let claimedByVMName: String?
}

struct HostUSBDeviceResponse: Content {
    let id: String
    let vendorId: String
    let productId: String
    let name: String
    let productName: String
    let manufacturer: String?
    let serial: String?
    let serialNumber: String?
    let bus: Int?
    let address: Int?
    let idUnstable: Bool
    let attachable: Bool
    let excludedReason: String?
    let busy: Bool
    let attachedToVmId: String?
    let claimedByVMId: String?
    let claimedByVMName: String?
}
