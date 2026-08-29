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

    public static let homebrewServiceLabel = "homebrew.mxcl.socket_vmnet"

    public static let homebrewPlistCandidates = [
        "/Library/LaunchDaemons/homebrew.mxcl.socket_vmnet.plist",
        "/opt/homebrew/opt/socket_vmnet/homebrew.mxcl.socket_vmnet.plist",
        "/usr/local/opt/socket_vmnet/homebrew.mxcl.socket_vmnet.plist",
    ]

    public static let brewBinaryCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    public static let binaryCandidates = [
        "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet",
        "/opt/homebrew/bin/socket_vmnet",
        "/usr/local/opt/socket_vmnet/bin/socket_vmnet",
        "/usr/local/bin/socket_vmnet",
        "/opt/socket_vmnet/bin/socket_vmnet",
    ]

    public static func printArguments(label: String) -> [String] {
        ["print", "system/\(label)"]
    }

    public static func brewServicesStartArguments() -> [String] {
        ["services", "start", "socket_vmnet"]
    }

    public static func brewServicesStopArguments() -> [String] {
        ["services", "stop", "socket_vmnet"]
    }

    public static func firstExisting(
        _ paths: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> String? {
        paths.first(where: fileExists)
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

        /// Already-installed Homebrew formula. Never `brew install`.
        public static func startHomebrewService() throws {
            if let plist = firstExisting(homebrewPlistCandidates) {
                try bootstrap(plistPath: plist, label: homebrewServiceLabel)
                return
            }
            guard let brew = firstExisting(brewBinaryCandidates) else {
                throw BarkVisorError.preconditionFailed(SocketVmnetDiscovery.installHint)
            }
            let result = try PlatformProcess.run(
                path: brew,
                arguments: brewServicesStartArguments(),
                timeout: 30,
            )
            guard result.succeeded else {
                throw BarkVisorError.processSpawnFailed(
                    "brew services start socket_vmnet failed: \(result.stderrString)",
                )
            }
        }

        public static func stopHomebrewService() throws {
            _ = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: bootoutArguments(label: homebrewServiceLabel),
                timeout: 15,
            )
            if let brew = firstExisting(brewBinaryCandidates) {
                _ = try? PlatformProcess.run(
                    path: brew,
                    arguments: brewServicesStopArguments(),
                    timeout: 30,
                )
            }
        }

        public static func serviceLoaded(_ label: String) -> Bool {
            let result = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: printArguments(label: label),
                timeout: 8,
            )
            return result?.succeeded == true
        }

        private static func apply(interface: String, plistPath: String) throws {
            try bootstrap(plistPath: plistPath, label: label(interface: interface))
        }

        private static func bootstrap(plistPath: String, label: String) throws {
            _ = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: bootoutArguments(label: label),
                timeout: 15,
            )
            let result = try PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: bootstrapArguments(plistPath: plistPath),
                timeout: 15,
            )
            guard result.succeeded else {
                throw BarkVisorError.processSpawnFailed(
                    "launchctl bootstrap \(label) failed: \(result.stderrString)",
                )
            }
        }
    #endif
}
