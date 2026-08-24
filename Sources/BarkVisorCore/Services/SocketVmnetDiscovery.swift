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

    /// Host NICs the Homebrew shared socket typically attaches to. Never `"vmnet"` —
    /// that name is not a real interface and fails `NetworkCapability.requireBridgedInterface`.
    public static let sharedUplinkCandidates = ["en0", "en1"]

    /// Real host interface to hang the shared Homebrew socket on (template/network rows).
    public static func sharedUplinkInterface(
        interfaceExists: (String) -> Bool = HostInfoService.interfaceExists,
        extraNames: () -> [String] = { HostInfoService.listInterfaces().map(\.name) },
    ) -> String? {
        if let name = sharedUplinkCandidates.first(where: interfaceExists) {
            return name
        }
        return extraNames().first { name in
            !isLoopbackInterface(name) && interfaceExists(name)
        }
    }

    public static func isLoopbackInterface(_ name: String) -> Bool {
        name == "lo" || name == "lo0"
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
        sharedUplink: () -> String? = { sharedUplinkInterface() },
    ) -> [(interface: String, path: String)] {
        var found: [(String, String)] = []
        var seenPaths = Set<String>()
        var seenInterfaces = Set<String>()
        func add(_ interface: String, _ path: String) {
            guard fileExists(path), !seenPaths.contains(path), !seenInterfaces.contains(interface)
            else { return }
            seenPaths.insert(path)
            seenInterfaces.insert(interface)
            found.append((interface, path))
        }
        for dir in ["/opt/homebrew/var/run", "/usr/local/var/run", "/var/run"] {
            for name in listBridged(dir) where name.hasPrefix("socket_vmnet.bridged.") {
                let iface = String(name.dropFirst("socket_vmnet.bridged.".count))
                guard !iface.isEmpty else { continue }
                add(iface, "\(dir)/\(name)")
            }
        }
        // Shared Homebrew socket is not a host iface named "vmnet". Attach it to a
        // real uplink so template deploy / Network.bridge pass requireBridgedInterface.
        // One path only — extra Homebrew prefixes must not duplicate the interface key.
        if let iface = sharedUplink(), !iface.isEmpty, !isLoopbackInterface(iface) {
            if let path = sharedSocketPaths.first(where: fileExists) {
                add(iface, path)
            }
        }
        return found
    }

    public static func socketAvailable(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> Bool {
        if sharedSocketPaths.contains(where: fileExists) {
            return true
        }
        return !existingSockets(fileExists: fileExists, sharedUplink: { nil }).isEmpty
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
