import Foundation

// MARK: - Protocol

/// Abstracts privileged host operations (bridge daemons, software updates)
/// that require a macOS XPC helper. On Linux these ops are unavailable for MVP.
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

    /// Bridged networking (socket_vmnet) — single source: PlatformCapabilities.
    public static var isBridgedNetworkingSupported: Bool {
        PlatformCapabilities.supportsBridgedNetworking
    }

    /// In-app privileged software updates — single source: PlatformCapabilities.
    public static var isUpdateInstallSupported: Bool {
        PlatformCapabilities.supportsInAppUpdate
    }

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

// MARK: - Linux / no-op implementation

/// No-op privilege backend for Linux (and other non-macOS hosts).
/// Bridge and update ops throw clear errors; bridge state listing returns empty.
public struct LinuxPrivilegeService: PrivilegeServicing {
    public var isAvailable: Bool {
        false
    }

    public init() {}

    public func installBridge(interface: String) async throws {
        throw Self.bridgedUnsupported
    }

    public func removeBridge(interface: String) async throws {
        throw Self.bridgedUnsupported
    }

    public func startBridge(interface: String) async throws {
        throw Self.bridgedUnsupported
    }

    public func stopBridge(interface: String) async throws {
        throw Self.bridgedUnsupported
    }

    public func bridgeStatus(interface: String) async throws -> String {
        throw Self.bridgedUnsupported
    }

    public func getAllBridgeStates() async throws -> [BridgeStateDTO] {
        // Empty list keeps bridge sync a quiet no-op on Linux.
        []
    }

    public func installUpdate(packagePath: String, expectedVersion: String) async throws {
        throw BarkVisorError.updateFailed(
            "In-app software updates are not supported on Linux yet. "
                + "Update BarkVisor using your package manager or release artifacts.",
        )
    }

    private static var bridgedUnsupported: BarkVisorError {
        .badRequest(
            "Bridged networking is not supported on Linux yet. Use NAT networking for the Linux MVP.",
        )
    }
}

/// Alias used by call sites / tests that prefer a no-op name.
public typealias NoopPrivilegeService = LinuxPrivilegeService
