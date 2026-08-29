import Foundation

/// BarkVisor-owned `socket_vmnet` LaunchDaemon (not Homebrew `brew services`, not XPC).
///
/// The root Device daemon writes `/Library/LaunchDaemons/dev.barkvisor.socket-vmnet.<iface>.plist`
/// and `launchctl bootstrap`s it. Packages stay user-brew (`brew install socket_vmnet`).
/// Never `sudo brew install` against a user Homebrew prefix.
public enum SocketVmnetLaunchd {
    public static let labelPrefix = "dev.barkvisor.socket-vmnet"
    public static let launchDaemonsDir = "/Library/LaunchDaemons"

    public static func label(interface: String) -> String {
        "\(labelPrefix).\(interface)"
    }

    public static func plistURL(
        interface: String,
        directory: String = launchDaemonsDir,
    ) -> URL {
        URL(fileURLWithPath: directory)
            .appendingPathComponent("\(label(interface: interface)).plist")
    }

    public static func socketPath(interface: String) -> String {
        "/var/run/socket_vmnet.bridged.\(interface)"
    }

    public static func plistXML(
        interface: String,
        binary: String,
        socketPath: String,
    ) -> String {
        let label = label(interface: interface)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>--vmnet-mode=bridged</string>
                <string>--vmnet-interface=\(interface)</string>
                <string>\(socketPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
    }

    public static func bootoutArguments(label: String) -> [String] {
        ["bootout", "system/\(label)"]
    }

    public static func bootstrapArguments(plistPath: String) -> [String] {
        ["bootstrap", "system", plistPath]
    }

    public static func kickstartArguments(label: String) -> [String] {
        ["kickstart", "-k", "system/\(label)"]
    }

    #if os(macOS)
        public static func install(interface: String) throws {
            try validateBridgeName(interface)
            let binary = try BundleResolver.optHelper(
                "socket_vmnet",
                package: "socket_vmnet",
                extraPaths: [
                    "/opt/homebrew/bin/socket_vmnet",
                    "/usr/local/bin/socket_vmnet",
                    "/opt/socket_vmnet/bin/socket_vmnet",
                ],
            )
            let plist = plistURL(interface: interface)
            let sock = socketPath(interface: interface)
            let xml = plistXML(interface: interface, binary: binary.path, socketPath: sock)
            try xml.write(to: plist, atomically: true, encoding: .utf8)
            try apply(interface: interface, plistPath: plist.path)
        }

        public static func start(interface: String) throws {
            try validateBridgeName(interface)
            let plist = plistURL(interface: interface)
            if FileManager.default.fileExists(atPath: plist.path) {
                try apply(interface: interface, plistPath: plist.path)
            } else {
                try install(interface: interface)
            }
        }

        public static func stop(interface: String) throws {
            try validateBridgeName(interface)
            _ = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: bootoutArguments(label: label(interface: interface)),
                timeout: 15,
            )
        }

        public static func remove(interface: String) throws {
            try stop(interface: interface)
            let plist = plistURL(interface: interface)
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
            }
        }

        private static func apply(interface: String, plistPath: String) throws {
            let service = label(interface: interface)
            _ = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: bootoutArguments(label: service),
                timeout: 15,
            )
            let result = try PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: bootstrapArguments(plistPath: plistPath),
                timeout: 15,
            )
            guard result.succeeded else {
                throw BarkVisorError.processSpawnFailed(
                    "launchctl bootstrap \(service) failed: \(result.stderrString)",
                )
            }
        }
    #endif
}
