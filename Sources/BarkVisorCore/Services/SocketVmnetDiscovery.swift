import Foundation

/// `socket_vmnet` sockets (Homebrew package or lima). The root Device daemon
/// starts a BarkVisor-owned plist via launchctl. Do not `sudo brew install`.
public enum SocketVmnetDiscovery {
    public static let installHint =
        "brew install socket_vmnet (do not sudo brew install). The Device starts socket_vmnet as root"

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

    public static func resolveUplink(
        forBridge name: String,
        dataDir: URL = Config.dataDir,
    ) -> String {
        if let uplink = LinuxHostBridgeApply.readOwnerMarker(bridge: name, dataDir: dataDir)?.uplink,
           !uplink.isEmpty {
            return uplink
        }
        return name
    }

    public static func bridgeName(
        forUplink uplink: String,
        dataDir: URL = Config.dataDir,
    ) -> String? {
        LinuxHostBridgeApply.listOwnerMarkers(dataDir: dataDir)
            .first(where: { $0.uplink == uplink })?
            .bridge
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
        listBridged: (String) -> [String] = { dir in
            (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        },
        sharedUplink: () -> String? = { sharedUplinkInterface() },
        dataDir: URL = Config.dataDir,
    ) -> [BridgeStateDTO] {
        let sockets = existingSockets(
            fileExists: fileExists,
            listBridged: listBridged,
            sharedUplink: sharedUplink,
        )
        let markers = LinuxHostBridgeApply.listOwnerMarkers(dataDir: dataDir)
        if !markers.isEmpty {
            let pathByUplink = Dictionary(uniqueKeysWithValues: sockets.map { ($0.interface, $0.path) })
            return markers.compactMap { marker in
                guard let uplink = marker.uplink, !uplink.isEmpty else { return nil }
                let path = pathByUplink[uplink]
                return BridgeStateDTO(
                    interface: marker.bridge,
                    socketPath: path,
                    plistExists: false,
                    daemonRunning: path != nil,
                    status: path != nil ? "active" : "inactive",
                )
            }
        }
        return sockets.map { item in
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
