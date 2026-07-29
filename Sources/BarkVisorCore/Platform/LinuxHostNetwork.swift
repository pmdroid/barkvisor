import Foundation

/// Linux host bridge / netdev discovery via sysfs.
/// Used for QEMU `-netdev bridge,br=…` (not macOS socket_vmnet).
public enum LinuxHostNetwork {
    /// Directory listing of `/sys/class/net`.
    public static var netClassPath: String {
        "/sys/class/net"
    }

    /// True if `name` exists as a network interface.
    public static func interfaceExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(netClassPath)/\(name)")
    }

    /// True if `name` is a Linux bridge (has `bridge/` sysfs subtree).
    public static func isBridgeInterface(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        let path = "\(netClassPath)/\(name)/bridge"
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Names of bridge devices on the host (e.g. `br0`).
    public static func listBridgeInterfaces() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: netClassPath)
        else {
            return []
        }
        return entries.filter { isBridgeInterface($0) }.sorted()
    }

    /// Validate that `name` is usable as QEMU bridge backend target.
    /// Prefer real bridge devices; allow any existing iface (helper can attach).
    public static func requireBridgeableInterface(_ name: String) throws {
        guard interfaceExists(name) else {
            throw BarkVisorError.bridgeNotReady(
                "Host interface '\(name)' not found under \(netClassPath). "
                    + "Create a Linux bridge first, e.g.:\n"
                    + "  sudo ip link add name \(name) type bridge\n"
                    + "  sudo ip link set \(name) up\n"
                    + "  sudo ip link set <phys> master \(name)\n"
                    + "And allow QEMU: echo 'allow \(name)' | sudo tee -a /etc/qemu/bridge.conf",
            )
        }
    }
}
