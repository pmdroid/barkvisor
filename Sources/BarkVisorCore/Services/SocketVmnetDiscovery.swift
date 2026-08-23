import Foundation

/// Operator-managed `socket_vmnet` sockets (Homebrew or lima). BarkVisor never
/// installs, starts, or stops these daemons (PAS-294).
public enum SocketVmnetDiscovery {
    public static let installHint =
        "brew install socket_vmnet && sudo brew services start socket_vmnet"

    public static let sharedSocketPaths = [
        "/opt/homebrew/var/run/socket_vmnet",
        "/usr/local/var/run/socket_vmnet",
        "/var/run/socket_vmnet",
    ]

    public static func isSharedSocketPath(_ path: String) -> Bool {
        sharedSocketPaths.contains(path)
    }

    public static func perInterfaceSocketPaths(_ interface: String) -> [String] {
        [
            "/opt/homebrew/var/run/socket_vmnet.bridged.\(interface)",
            "/usr/local/var/run/socket_vmnet.bridged.\(interface)",
            "/var/run/socket_vmnet.bridged.\(interface)",
        ]
    }

    /// Per-iface first (operator lima bridged plist), then Homebrew shared service.
    public static func candidates(bridgeInterface: String) -> [String] {
        perInterfaceSocketPaths(bridgeInterface) + sharedSocketPaths
    }

    public static func existingSockets(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        listBridged: (String) -> [String] = { dir in
            (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        },
    ) -> [(interface: String, path: String)] {
        var found: [(String, String)] = []
        var seen = Set<String>()
        func add(_ interface: String, _ path: String) {
            guard fileExists(path), !seen.contains(path) else { return }
            seen.insert(path)
            found.append((interface, path))
        }
        for dir in ["/opt/homebrew/var/run", "/usr/local/var/run", "/var/run"] {
            for name in listBridged(dir) where name.hasPrefix("socket_vmnet.bridged.") {
                let iface = String(name.dropFirst("socket_vmnet.bridged.".count))
                guard !iface.isEmpty else { continue }
                add(iface, "\(dir)/\(name)")
            }
        }
        for path in sharedSocketPaths {
            add("vmnet", path)
        }
        return found
    }

    public static func socketAvailable(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> Bool {
        !existingSockets(fileExists: fileExists).isEmpty
    }

    public static func bridgeStates(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> [BridgeStateDTO] {
        existingSockets(fileExists: fileExists).map { item in
            BridgeStateDTO(
                interface: item.interface,
                socketPath: item.path,
                plistExists: false,
                daemonRunning: true,
                status: "active",
            )
        }
    }
}
