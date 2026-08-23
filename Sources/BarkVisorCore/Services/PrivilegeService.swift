import Foundation

// MARK: - Protocol

/// Abstracts privileged host operations (bridge daemons).
///
/// - **macOS:** XPC helper (`HelperXPCClient`) for socket_vmnet lifecycle.
/// - **Linux:** host-bridge validation only (no XPC).
///
/// Controllers and other call sites must use `PrivilegeService.shared` only —
/// never call `HelperXPCClient` directly (enforced by PrivilegeBoundaryTests).
public protocol PrivilegeServicing: Sendable {
    /// Whether this platform can perform privileged bridge ops.
    var isAvailable: Bool { get }

    func installBridge(interface: String) async throws
    func removeBridge(interface: String) async throws
    func startBridge(interface: String) async throws
    func stopBridge(interface: String) async throws
    func bridgeStatus(interface: String) async throws -> String
    func getAllBridgeStates() async throws -> [BridgeStateDTO]
}

// MARK: - Factory

public enum PrivilegeService {
    /// Platform-selected privilege backend.
    public static let shared: any PrivilegeServicing = makeShared()

    // Capability checks live on PlatformCapabilities (call that type directly).

    private static func makeShared() -> any PrivilegeServicing {
        #if os(macOS)
            MacOSPrivilegeService()
        #else
            LinuxPrivilegeService()
        #endif
    }
}

// MARK: - macOS implementation

#if os(macOS)
    /// Wraps the privileged XPC helper for bridge operations.
    public struct MacOSPrivilegeService: PrivilegeServicing {
        public var isAvailable: Bool {
            true
        }

        public init() {}

        public func installBridge(interface: String) async throws {
            try await HelperXPCClient.shared.installBridge(interface: interface)
        }

        public func removeBridge(interface: String) async throws {
            try await HelperXPCClient.shared.removeBridge(interface: interface)
        }

        public func startBridge(interface: String) async throws {
            try await HelperXPCClient.shared.startBridge(interface: interface)
        }

        public func stopBridge(interface: String) async throws {
            try await HelperXPCClient.shared.stopBridge(interface: interface)
        }

        public func bridgeStatus(interface: String) async throws -> String {
            try await HelperXPCClient.shared.bridgeStatus(interface: interface)
        }

        public func getAllBridgeStates() async throws -> [BridgeStateDTO] {
            try await HelperXPCClient.shared.getAllBridgeStates()
        }
    }
#endif

// MARK: - Linux implementation

/// Linux privilege backend.
/// Bridging uses host Linux bridges + QEMU `bridge` netdev (no XPC helper).
public struct LinuxPrivilegeService: PrivilegeServicing {
    /// Bridge registration does not need a privileged helper process.
    public var isAvailable: Bool {
        true
    }

    public init() {}

    public func installBridge(interface: String) async throws {
        try LinuxHostNetwork.requireBridgeableInterface(interface)
        // QEMU attaches at VM start; nothing daemon-like to install.
    }

    public func removeBridge(interface: String) async throws {
        // Host bridges are managed outside BarkVisor (ip/netplan/NetworkManager).
        // Treat remove as a no-op so the UI can clear bookkeeping records.
        _ = interface
    }

    public func startBridge(interface: String) async throws {
        try LinuxHostNetwork.requireBridgeableInterface(interface)
    }

    public func stopBridge(interface: String) async throws {
        // Stopping a system bridge is out of scope; VMs simply detach on stop.
        _ = interface
    }

    public func bridgeStatus(interface: String) async throws -> String {
        // Same existence policy as HostInfoService / requireBridgeableInterface (sysfs on Linux).
        if HostInfoService.interfaceExists(interface) {
            return "active"
        }
        return "inactive"
    }

    public func getAllBridgeStates() async throws -> [BridgeStateDTO] {
        // Discovery is HostBridgeFacts (sysfs). Do not mint macOS plist/daemon rows.
        []
    }
}

/// Alias used by call sites / tests that prefer a no-op name.
public typealias NoopPrivilegeService = LinuxPrivilegeService
