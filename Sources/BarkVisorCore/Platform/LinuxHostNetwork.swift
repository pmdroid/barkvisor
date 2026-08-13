import Foundation

/// Linux host bridge / netdev discovery via sysfs.
/// Used for QEMU `-netdev bridge,br=…` (not macOS socket_vmnet).
///
/// **Existence policy:** a name under `/sys/class/net` is present even if the
/// interface is administratively down or has no IP address. Prefer
/// `HostInfoService.interfaceExists` from cross-platform call sites; that API
/// delegates here on Linux so setup, privilege, and VM start agree.
public enum LinuxHostNetwork {
    /// Directory listing of `/sys/class/net`.
    public static var netClassPath: String {
        "/sys/class/net"
    }

    /// True if `name` exists as a network interface (sysfs; down/no-IP count).
    public static func interfaceExists(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            return false
        }
        return FileManager.default.fileExists(atPath: "\(netClassPath)/\(name)")
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

    /// Default qemu-bridge-helper ACL (`allow br0` / `allow all`).
    public static let defaultBridgeACLPath = "/etc/qemu/bridge.conf"

    /// Parse qemu-bridge-helper ACL contents. Comments (`#`) and blank lines ignored.
    public static func bridgeACLAllows(_ name: String, fileContents: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            return false
        }
        for raw in fileContents.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if line == "allow all" || line == "allow \(name)" {
                return true
            }
        }
        return false
    }

    /// `true`/`false` when `path` is readable; `nil` if the file is missing or unreadable
    /// (fail open — do not invent a denial).
    public static func bridgeACLDecision(_ name: String, at path: String = defaultBridgeACLPath)
        -> Bool? {
        guard FileManager.default.isReadableFile(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return nil
        }
        return bridgeACLAllows(name, fileContents: contents)
    }

    /// Validate that `name` is usable as QEMU bridge backend target.
    /// Prefer real bridge devices; allow any existing iface (helper can attach).
    public static func requireBridgeableInterface(_ name: String) throws {
        guard interfaceExists(name) else {
            throw BarkVisorError.interfaceMissing(name)
        }
    }
}
