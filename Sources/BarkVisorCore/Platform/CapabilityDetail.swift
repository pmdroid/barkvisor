import Foundation

/// Stable feature codes projected on `/api/system/capabilities` (PAS-37).
///
/// Wave 0 covers flags that already exist on `VirtualizationFeatures` plus
/// `tcgOnly` so Linux-without-KVM has an explicit reason. GPU/VFIO wait for
/// PAS-88.
public enum CapabilityCode: String, Codable, Sendable, CaseIterable {
    case bridgedNetworking
    case managedBridgeDaemon
    case usbPassthrough
    case inAppUpdate
    case kvmDevice
    case qemuBridgeHelper
    case tcgOnly
}

/// Stable reason tokens for unsupported / degraded capabilities (PAS-37 / PAS-94).
public enum CapabilityReasonCode: String, Codable, Sendable {
    case osUnsupported = "os_unsupported"
    case kvmMissing = "kvm_missing"
    case helperMissing = "helper_missing"
    case interfaceMissing = "interface_missing"
    case aclDenied = "acl_denied"
    case linuxOsManaged = "linux_os_managed"
    case linuxPkgUpdate = "linux_pkg_update"
}

/// Per-mode support + PAS-94 reason/remediation (PAS-57 / PAS-67).
public struct NetworkModeCapability: Codable, Sendable, Equatable {
    public var mode: String
    public var supported: Bool
    public var reasonCode: String?
    public var remediation: String?
    public var label: String?
    public var description: String?

    public init(
        mode: String,
        supported: Bool,
        reasonCode: String? = nil,
        remediation: String? = nil,
        label: String? = nil,
        description: String? = nil,
    ) {
        self.mode = mode
        self.supported = supported
        self.reasonCode = reasonCode
        self.remediation = remediation
        self.label = label
        self.description = description
    }

    public init(
        mode: NetworkMode,
        supported: Bool,
        reasonCode: String? = nil,
        remediation: String? = nil,
    ) {
        self.init(
            mode: mode.rawValue,
            supported: supported,
            reasonCode: reasonCode,
            remediation: remediation,
            label: mode.label,
            description: mode.intentDescription,
        )
    }
}

/// Per-feature support + optional reason/remediation.
public struct CapabilityDetail: Codable, Sendable, Equatable {
    public var code: CapabilityCode
    public var supported: Bool
    public var reasonCode: String?
    public var remediation: String?

    public init(
        code: CapabilityCode,
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
        code: CapabilityCode,
        supported: Bool,
        reason: CapabilityReasonCode?,
        remediation: String? = nil,
    ) {
        self.init(
            code: code,
            supported: supported,
            reasonCode: reason?.rawValue,
            remediation: remediation,
        )
    }
}

/// Builds `CapabilityDetail` rows from a `HostInventory` snapshot.
///
/// Inventory booleans stay the source of truth. Messages live here so APIs
/// and UI (PAS-94) share one catalog instead of scattered `#if` strings.
public enum CapabilityDetailBuilder {
    public static func from(inventory: HostInventory) -> [CapabilityDetail] {
        CapabilityCode.allCases.map { detail(for: $0, inventory: inventory) }
    }

    /// NAT and isolated are always available. Bridged reuses the PAS-94 row.
    public static func networkModes(from inventory: HostInventory) -> [NetworkModeCapability] {
        let bridged = detail(for: .bridgedNetworking, inventory: inventory)
        return [
            NetworkModeCapability(mode: .nat, supported: true),
            NetworkModeCapability(
                mode: .bridged,
                supported: bridged.supported,
                reasonCode: bridged.reasonCode,
                remediation: bridged.remediation,
            ),
            NetworkModeCapability(mode: .isolated, supported: true),
        ]
    }

    public static func detail(for code: CapabilityCode, inventory: HostInventory) -> CapabilityDetail {
        let os = inventory.platform.os
        let features = inventory.virtualization.features
        let accel = inventory.virtualization.accelerator
        switch code {
        case .bridgedNetworking:
            return bridgedNetworking(os: os, supported: features.bridgedNetworking)
        case .managedBridgeDaemon:
            return managedBridgeDaemon(os: os, supported: features.managedBridgeDaemon)
        case .usbPassthrough:
            return usbPassthrough(os: os, supported: features.usbPassthrough)
        case .inAppUpdate:
            return inAppUpdate(os: os, supported: features.inAppUpdate)
        case .kvmDevice:
            return kvmDevice(os: os, supported: features.kvmDevice)
        case .qemuBridgeHelper:
            return qemuBridgeHelper(os: os, supported: features.qemuBridgeHelper)
        case .tcgOnly:
            return tcgOnly(os: os, accelerator: accel, kvmPresent: features.kvmDevice)
        }
    }

    /// Platform-correct remediation (also used when throwing `unsupportedFeature`).
    public static func remediation(for feature: PlatformCapabilities.Feature, os: String) -> String {
        switch feature {
        case .bridgedNetworking:
            return bridgedNetworking(os: os, supported: false).remediation ?? ""
        case .managedBridgeDaemon:
            return managedBridgeDaemon(os: os, supported: false).remediation ?? ""
        case .usbPassthrough:
            return usbPassthrough(os: os, supported: false).remediation ?? ""
        case .inAppUpdate:
            return inAppUpdate(os: os, supported: false).remediation ?? ""
        }
    }

    // MARK: - Features

    private static func bridgedNetworking(os: String, supported: Bool) -> CapabilityDetail {
        guard !supported else {
            return CapabilityDetail(code: .bridgedNetworking, supported: true)
        }
        if isLinux(os) {
            return CapabilityDetail(
                code: .bridgedNetworking,
                supported: false,
                reason: .helperMissing,
                remediation: "Bridged networking requires a host bridge and qemu-bridge-helper "
                    + "(e.g. br0 + /etc/qemu/bridge.conf). Use NAT if bridging is unavailable.",
            )
        }
        return CapabilityDetail(
            code: .bridgedNetworking,
            supported: false,
            reason: .osUnsupported,
            remediation: "Bridged networking is not supported on this platform. Use NAT networking.",
        )
    }

    private static func managedBridgeDaemon(os: String, supported: Bool) -> CapabilityDetail {
        guard !supported else {
            return CapabilityDetail(code: .managedBridgeDaemon, supported: true)
        }
        if isLinux(os) {
            return CapabilityDetail(
                code: .managedBridgeDaemon,
                supported: false,
                reason: .linuxOsManaged,
                remediation: "Managed bridge daemon lifecycle is not supported on Linux. "
                    + "Create a host bridge with ip/netplan (e.g. br0), then attach VMs "
                    + "via a Bridged network record.",
            )
        }
        return CapabilityDetail(
            code: .managedBridgeDaemon,
            supported: false,
            reason: .osUnsupported,
            remediation: "Managed bridge daemon lifecycle is not supported on this platform.",
        )
    }

    private static func usbPassthrough(os: String, supported: Bool) -> CapabilityDetail {
        guard !supported else {
            return CapabilityDetail(code: .usbPassthrough, supported: true)
        }
        if isLinux(os) {
            return CapabilityDetail(
                code: .usbPassthrough,
                supported: false,
                reason: .osUnsupported,
                remediation: "USB passthrough is not available (install usbutils / check udev permissions).",
            )
        }
        return CapabilityDetail(
            code: .usbPassthrough,
            supported: false,
            reason: .osUnsupported,
            remediation: "USB passthrough is not supported on this platform.",
        )
    }

    private static func inAppUpdate(os: String, supported: Bool) -> CapabilityDetail {
        guard !supported else {
            return CapabilityDetail(code: .inAppUpdate, supported: true)
        }
        if isLinux(os) {
            return CapabilityDetail(
                code: .inAppUpdate,
                supported: false,
                reason: .linuxPkgUpdate,
                remediation: "In-app software updates are not supported on Linux yet. "
                    + "Update BarkVisor using your package manager or release artifacts.",
            )
        }
        return CapabilityDetail(
            code: .inAppUpdate,
            supported: false,
            reason: .osUnsupported,
            remediation: "In-app software updates are not supported on this platform.",
        )
    }

    private static func kvmDevice(os: String, supported: Bool) -> CapabilityDetail {
        guard !supported else {
            return CapabilityDetail(code: .kvmDevice, supported: true)
        }
        if isLinux(os) {
            return CapabilityDetail(
                code: .kvmDevice,
                supported: false,
                reason: .kvmMissing,
                remediation: kvmMissingRemediation,
            )
        }
        return CapabilityDetail(
            code: .kvmDevice,
            supported: false,
            reason: .osUnsupported,
            remediation: "KVM is a Linux hypervisor interface. This host uses HVF (or TCG) instead.",
        )
    }

    private static func qemuBridgeHelper(os: String, supported: Bool) -> CapabilityDetail {
        guard !supported else {
            return CapabilityDetail(code: .qemuBridgeHelper, supported: true)
        }
        if isLinux(os) {
            return CapabilityDetail(
                code: .qemuBridgeHelper,
                supported: false,
                reason: .helperMissing,
                remediation: "qemu-bridge-helper was not found. Bridged networking needs the helper "
                    + "and /etc/qemu/bridge.conf. Use NAT if bridging is unavailable.",
            )
        }
        return CapabilityDetail(
            code: .qemuBridgeHelper,
            supported: false,
            reason: .osUnsupported,
            remediation: "qemu-bridge-helper is a Linux QEMU tool. macOS uses the managed socket_vmnet helper.",
        )
    }

    private static func tcgOnly(os: String, accelerator: String, kvmPresent: Bool) -> CapabilityDetail {
        let usingTCG = accelerator == "tcg"
        guard usingTCG else {
            return CapabilityDetail(code: .tcgOnly, supported: false)
        }
        if isLinux(os), !kvmPresent {
            return CapabilityDetail(
                code: .tcgOnly,
                supported: true,
                reason: .kvmMissing,
                remediation: kvmMissingRemediation,
            )
        }
        return CapabilityDetail(
            code: .tcgOnly,
            supported: true,
            reason: .kvmMissing,
            remediation: "This host is using TCG software emulation (no hardware accelerator).",
        )
    }

    private static let kvmMissingRemediation =
        "KVM is not available (/dev/kvm missing). Guests run under TCG (software emulation). "
            + "Install qemu-kvm, add the user to the kvm group, or enable nested virtualization."

    private static func isLinux(_ os: String) -> Bool {
        os.caseInsensitiveCompare("Linux") == .orderedSame
    }
}
