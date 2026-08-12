import Foundation

/// Wave 0 network modes (`nat` | `bridged`). Isolated / tailnet wait for PAS-67.
public enum NetworkCapability {
    public static let modes = ["nat", "bridged"]

    public static func requireMode(_ mode: String) throws {
        guard modes.contains(mode) else {
            throw BarkVisorError.badRequest("mode must be 'nat' or 'bridged'")
        }
        if mode == "bridged" {
            try PlatformCapabilities.requireBridgedNetworking()
        }
    }

    /// Fail closed before persist or QEMU (PAS-57).
    ///
    /// Checks product bridged capability, IFNAMSIZ-safe name, that the host
    /// interface exists (`HostInfoService.interfaceExists`), and (Linux) that
    /// a readable qemu-bridge-helper ACL allows the name.
    public static func requireBridgedInterface(_ name: String) throws {
        try PlatformCapabilities.requireBridgedNetworking()
        try validateBridgeName(name)
        guard HostInfoService.interfaceExists(name) else {
            throw BarkVisorError.interfaceMissing(name)
        }
        #if os(Linux)
            if let allowed = LinuxHostNetwork.bridgeACLDecision(name), !allowed {
                throw BarkVisorError.bridgeHelperDenied(name)
            }
        #endif
    }
}
