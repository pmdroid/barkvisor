import Foundation

// MARK: - Protocol

/// Abstracts privileged host operations (bridge daemons, in-app updates).
///
/// - **macOS:** XPC helper (`HelperXPCClient`) for socket_vmnet lifecycle and PKG updates.
/// - **Linux:** host-bridge validation only (no XPC); in-app updates are unsupported
///   (`PlatformCapabilities.supportsInAppUpdate` is false — use the package manager).
///
/// Controllers and other call sites must use `PrivilegeService.shared` only —
/// never call `HelperXPCClient` directly (enforced by PrivilegeBoundaryTests).
public protocol PrivilegeServicing: Sendable {
    /// Whether this platform can perform privileged bridge / update ops.
    var isAvailable: Bool { get }

    func installBridge(interface: String) async throws
    func removeBridge(interface: String) async throws
    func startBridge(interface: String) async throws
    func stopBridge(interface: String) async throws
    func bridgeStatus(interface: String) async throws -> String
    func getAllBridgeStates() async throws -> [BridgeStateDTO]
    func installUpdate(packagePath: String, expectedVersion: String) async throws
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
    /// Wraps the privileged XPC helper for bridge and update operations.
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

        public func installUpdate(packagePath: String, expectedVersion: String) async throws {
            try await HelperXPCClient.shared.installUpdate(
                packagePath: packagePath,
                expectedVersion: expectedVersion,
            )
        }
    }
#endif

// MARK: - Linux implementation

/// Linux privilege backend.
/// Bridging uses host Linux bridges + QEMU `bridge` netdev (no XPC helper).
/// Updates remain package-manager only.
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
        // Report all host bridge devices so BridgeSync can mark them active.
        LinuxHostNetwork.listBridgeInterfaces().map { name in
            BridgeStateDTO(
                interface: name,
                socketPath: nil,
                plistExists: true,
                daemonRunning: true,
                status: "active",
            )
        }
    }

    public func installUpdate(packagePath: String, expectedVersion: String) async throws {
        try PlatformCapabilities.requireInAppUpdate()
    }
}

/// Alias used by call sites / tests that prefer a no-op name.
public typealias NoopPrivilegeService = LinuxPrivilegeService
