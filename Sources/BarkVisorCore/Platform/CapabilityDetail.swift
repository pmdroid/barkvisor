import Foundation

/// Stable reason tokens for unsupported capabilities (PAS-94; shared with PAS-37).
public enum CapabilityReasonCode: String, Codable, Sendable {
    case osUnsupported = "os_unsupported"
    case helperMissing = "helper_missing"
    case linuxOsManaged = "linux_os_managed"
    case linuxPkgUpdate = "linux_pkg_update"
}

/// Per-feature support + optional reason/remediation on `/api/system/capabilities`.
///
/// Booleans on the capabilities document stay for older clients. `code` matches
/// `PlatformCapabilities.Feature.rawValue` (camelCase). API error `code` values
/// use the snake_case `Feature.errorCode` instead.
public struct CapabilityDetail: Codable, Sendable, Equatable {
    public var code: String
    public var supported: Bool
    public var reasonCode: String?
    public var remediation: String?

    public init(
        code: String,
        supported: Bool,
        reasonCode: String? = nil,
        remediation: String? = nil,
    ) {
        self.code = code
        self.supported = supported
        self.reasonCode = reasonCode
        self.remediation = remediation
    }

    public init(
        code: PlatformCapabilities.Feature,
        supported: Bool,
        reason: CapabilityReasonCode?,
        remediation: String? = nil,
    ) {
        self.init(
            code: code.rawValue,
            supported: supported,
            reasonCode: reason?.rawValue,
            remediation: remediation,
        )
    }
}

/// Builds `CapabilityDetail` rows from a `HostInventory` snapshot.
///
/// Inventory booleans stay the source of truth. Messages live here so APIs
/// and UI share one catalog instead of scattered `#if` strings.
public enum CapabilityDetailBuilder {
    /// Product features PAS-94 explains in the UI (USB, bridged, updates, managed daemon).
    public static let projectedFeatures: [PlatformCapabilities.Feature] = [
        .bridgedNetworking,
        .managedBridgeDaemon,
        .usbPassthrough,
        .inAppUpdate,
    ]

    public static func from(inventory: HostInventory) -> [CapabilityDetail] {
        projectedFeatures.map { detail(for: $0, inventory: inventory) }
    }

    public static func detail(
        for feature: PlatformCapabilities.Feature,
        inventory: HostInventory,
    ) -> CapabilityDetail {
        let os = inventory.platform.os
        let features = inventory.virtualization.features
        let supported = isSupported(feature, features: features)
        guard !supported else {
            return CapabilityDetail(code: feature, supported: true, reason: nil)
        }
        return CapabilityDetail(
            code: feature,
            supported: false,
            reason: reasonCode(for: feature, os: os),
            remediation: remediation(for: feature, os: os),
        )
    }

    /// Platform-correct remediation (also used when throwing `unsupportedFeature`).
    public static func remediation(for feature: PlatformCapabilities.Feature, os: String) -> String {
        switch feature {
        case .bridgedNetworking:
            if isLinux(os) {
                return "Bridged networking requires a host bridge and qemu-bridge-helper "
                    + "(e.g. br0 + /etc/qemu/bridge.conf). Use NAT if bridging is unavailable."
            }
            if isMacOS(os) {
                return "Bridged networking is not supported on this host. Use NAT networking."
            }
            return "Bridged networking is not supported on this platform. Use NAT networking."
        case .managedBridgeDaemon:
            if isLinux(os) {
                return "Managed bridge daemon lifecycle is not supported on Linux. "
                    + "Create a host bridge with ip/netplan (e.g. br0), then attach VMs "
                    + "via a Bridged network record."
            }
            return "Managed bridge daemon lifecycle is not supported on this platform."
        case .usbPassthrough:
            if isLinux(os) {
                return "USB passthrough is not available (install usbutils / check udev permissions)."
            }
            return "USB passthrough is not supported on this platform."
        case .inAppUpdate:
            if isLinux(os) {
                return "In-app software updates are not supported on Linux yet. "
                    + "Update BarkVisor using your package manager or release artifacts."
            }
            return "In-app software updates are not supported on this platform."
        }
    }

    private static func reasonCode(
        for feature: PlatformCapabilities.Feature,
        os: String,
    ) -> CapabilityReasonCode {
        switch feature {
        case .bridgedNetworking:
            return isLinux(os) ? .helperMissing : .osUnsupported
        case .managedBridgeDaemon:
            return isLinux(os) ? .linuxOsManaged : .osUnsupported
        case .usbPassthrough:
            return .osUnsupported
        case .inAppUpdate:
            return isLinux(os) ? .linuxPkgUpdate : .osUnsupported
        }
    }

    private static func isSupported(
        _ feature: PlatformCapabilities.Feature,
        features: VirtualizationFeatures,
    ) -> Bool {
        switch feature {
        case .bridgedNetworking: return features.bridgedNetworking
        case .managedBridgeDaemon: return features.managedBridgeDaemon
        case .usbPassthrough: return features.usbPassthrough
        case .inAppUpdate: return features.inAppUpdate
        }
    }

    private static func isLinux(_ os: String) -> Bool {
        os.caseInsensitiveCompare("Linux") == .orderedSame
    }

    private static func isMacOS(_ os: String) -> Bool {
        os.caseInsensitiveCompare("macOS") == .orderedSame
    }
}
