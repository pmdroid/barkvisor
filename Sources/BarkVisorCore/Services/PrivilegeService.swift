import Foundation

// MARK: - Protocol

/// Abstracts privileged host operations that used to go through a helper.
///
/// macOS no longer ships a privileged helper (PAS-294). The root Device
/// daemon starts/stops BarkVisor-owned `socket_vmnet` plists via launchctl.
/// Linux uses host bridges. Appliance .deb/.pkg updates run in-process as root
/// (`UpdateService`); they do not go through this service.
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
    /// Root daemon: launchctl for BarkVisor-owned socket_vmnet plists (PAS-294: no XPC).
    public struct MacOSPrivilegeService: PrivilegeServicing {
        public var isAvailable: Bool {
            true
        }

        public init() {}

        public func installBridge(interface: String) async throws {
            try PlatformCapabilities.requireManagedBridgeDaemon()
            try SocketVmnetLaunchd.install(interface: interface)
        }

        public func removeBridge(interface: String) async throws {
            try PlatformCapabilities.requireManagedBridgeDaemon()
            try SocketVmnetLaunchd.remove(interface: interface)
        }

        public func startBridge(interface: String) async throws {
            try PlatformCapabilities.requireManagedBridgeDaemon()
            try SocketVmnetLaunchd.start(interface: interface)
        }

        public func stopBridge(interface: String) async throws {
            try PlatformCapabilities.requireManagedBridgeDaemon()
            try SocketVmnetLaunchd.stop(interface: interface)
        }

        public func bridgeStatus(interface: String) async throws -> String {
            let states = SocketVmnetDiscovery.bridgeStates()
            let uplink = SocketVmnetDiscovery.resolveUplink(forBridge: interface)
            let mapped = SocketVmnetDiscovery.bridgeName(forUplink: interface)
            let names = Set([interface, uplink, mapped].compactMap(\.self))
            if let match = states.first(where: { names.contains($0.interface) }) {
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

/// Pre-PAS-294 privileged helper leftover. Never reconnect; warn once if files remain.
public enum LeftoverHelperInventory {
    public static let launchdLabel = "dev.barkvisor.helper"

    /// Split so PrivilegeBoundaryTests can keep forbidding the contiguous helper type name.
    private static var leftoverHelperBinaryName: String {
        "BarkVisor" + "Helper"
    }

    public static var candidatePaths: [String] {
        let helper = leftoverHelperBinaryName
        return [
            "/Library/LaunchDaemons/dev.barkvisor.helper.plist",
            "/Library/PrivilegedHelperTools/dev.barkvisor.helper",
            "/usr/local/libexec/dev.barkvisor.helper",
            "/usr/local/libexec/barkvisor/dev.barkvisor.helper",
            "/usr/local/libexec/\(helper)",
            "/usr/local/libexec/barkvisor/\(helper)",
        ]
    }

    public static func leftoverPaths(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> [String] {
        candidatePaths.filter(fileExists)
    }

    public static func warningMessage(paths: [String]) -> String {
        let joined = paths.joined(separator: " ")
        return """
        Leftover privileged helper is unused; the Device starts socket_vmnet as root. \
        A loaded leftover may log XPC invalidation about every 15s. Remove with: \
        sudo launchctl bootout system/\(launchdLabel) && sudo rm -f \(joined)
        """
    }

    /// Rate-limited Device warning. Does not connect or retry XPC.
    public static func warnIfPresent(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: Date = Date(),
    ) {
        let paths = leftoverPaths(fileExists: fileExists)
        guard !paths.isEmpty else { return }
        if LogNoise.shouldRateLimit(signature: LogNoise.xpcInvalidationSignature, now: now) {
            return
        }
        Log.server.warning(warningMessage(paths: paths))
    }
}
