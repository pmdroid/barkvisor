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
    /// Checks product bridged capability, IFNAMSIZ-safe name, and that the
    /// host interface exists (`HostInfoService.interfaceExists`).
    public static func requireBridgedInterface(_ name: String) throws {
        try PlatformCapabilities.requireBridgedNetworking()
        try validateBridgeName(name)
        guard HostInfoService.interfaceExists(name) else {
            throw BarkVisorError.interfaceMissing(name)
        }
    }
}
