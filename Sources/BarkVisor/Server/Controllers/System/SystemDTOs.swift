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

/// Platform feature flags for UI gating (bridged networking, USB, in-app updates).
struct SystemCapabilitiesResponse: Content {
    let platform: String
    /// VMs may use bridged networking (Linux host bridge or macOS socket_vmnet).
    let supportsBridgedNetworking: Bool
    /// Install/start/stop privileged bridge daemons (macOS socket_vmnet helper only).
    let supportsManagedBridgeDaemon: Bool
    let supportsUSBPassthrough: Bool
    let supportsInAppUpdate: Bool
    let accelerator: String
    let hostArch: String
    /// Online logical CPU count on the host (max assignable vCPUs per VM).
    let hostCpuCount: Int
    /// Canonical guest profiles (persisted `vmType` IDs).
    let guestTypes: [GuestTypeInfo]
}

struct HostUSBDeviceResponse: Content {
    let vendorId: String
    let productId: String
    let name: String
    let manufacturer: String?
    let serialNumber: String?
    let claimedByVMId: String?
    let claimedByVMName: String?
}
