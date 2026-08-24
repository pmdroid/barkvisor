import Foundation

// MARK: - Protocol

/// Abstracts privileged host operations that used to go through XPC.
///
/// macOS no longer ships a privileged XPC helper. Bridged/vmnet is Homebrew
/// `socket_vmnet` (`sudo brew services start socket_vmnet`). Linux uses host
/// bridges. In-app PKG updates are unsupported (`PlatformCapabilities`).
///
/// Controllers and other call sites must use `PrivilegeService.shared` only
/// (enforced by PrivilegeBoundaryTests).
public protocol PrivilegeServicing: Sendable {
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
    public static let shared: any PrivilegeServicing = makeShared()

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
    /// Probe-only: never load LaunchDaemons or bless a helper (PAS-294).
    public struct MacOSPrivilegeService: PrivilegeServicing {
        public var isAvailable: Bool {
            true
        }

        public init() {}

        public func installBridge(interface: String) async throws {
            _ = interface
            try PlatformCapabilities.requireManagedBridgeDaemon()
        }

        public func removeBridge(interface: String) async throws {
            _ = interface
            try PlatformCapabilities.requireManagedBridgeDaemon()
        }

        public func startBridge(interface: String) async throws {
            _ = interface
            try PlatformCapabilities.requireManagedBridgeDaemon()
        }

        public func stopBridge(interface: String) async throws {
            _ = interface
            try PlatformCapabilities.requireManagedBridgeDaemon()
        }

        public func bridgeStatus(interface: String) async throws -> String {
            let states = SocketVmnetDiscovery.bridgeStates()
            if let match = states.first(where: { $0.interface == interface }) {
                return match.status
            }
            if SocketVmnetDiscovery.socketAvailable() {
                return "active"
            }
            return "inactive"
        }

        public func getAllBridgeStates() async throws -> [BridgeStateDTO] {
            SocketVmnetDiscovery.bridgeStates()
        }
    }
#endif

// MARK: - Linux implementation

/// Linux privilege backend.
/// Bridging uses host Linux bridges + QEMU `bridge` netdev (no XPC helper).
public struct LinuxPrivilegeService: PrivilegeServicing {
    public var isAvailable: Bool {
        true
    }

    public init() {}

    public func installBridge(interface: String) async throws {
        try LinuxHostNetwork.requireBridgeableInterface(interface)
    }

    public func removeBridge(interface: String) async throws {
        _ = interface
    }

    public func startBridge(interface: String) async throws {
        try LinuxHostNetwork.requireBridgeableInterface(interface)
    }

    public func stopBridge(interface: String) async throws {
        _ = interface
    }

    public func bridgeStatus(interface: String) async throws -> String {
        if HostInfoService.interfaceExists(interface) {
            return "active"
        }
        return "inactive"
    }

    public func getAllBridgeStates() async throws -> [BridgeStateDTO] {
        []
    }
}

/// Alias used by call sites / tests that prefer a no-op name.
public typealias NoopPrivilegeService = LinuxPrivilegeService
