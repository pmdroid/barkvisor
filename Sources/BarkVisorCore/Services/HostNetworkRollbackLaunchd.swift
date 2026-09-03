import Foundation

public enum HostNetworkRollbackLaunchd {
    public static let labelPrefix = "dev.barkvisor.hostnet-rollback"
    public static let launchDaemonsDir = "/Library/LaunchDaemons"

    public static func label(target: String) -> String {
        "\(labelPrefix).\(target)"
    }

    public static func plistURL(target: String, directory: String = launchDaemonsDir) -> URL {
        URL(fileURLWithPath: directory)
            .appendingPathComponent("\(label(target: target)).plist")
    }

    public static func helperPath(target: String, dataDir: URL = Config.dataDir) -> String {
        dataDir.appendingPathComponent("host-network", isDirectory: true)
            .appendingPathComponent("\(target)-rollback.sh").path
    }

    public static func helperScript(binary: String, seconds: Int) -> String {
        """
        #!/bin/sh
        sleep \(seconds)
        exec "\(binary)" hostnet-expire
        """
    }

    public static func plistXML(target: String, helperPath: String) -> String {
        let job = label(target: target)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(job)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>\(helperPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
    }

    public static func binaryPath(
        launched: String = CommandLine.arguments[0],
        bundlePath: String? = Bundle.main.executableURL?.path,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> String {
        if let bundlePath, bundlePath.hasPrefix("/"), fileExists(bundlePath) {
            return bundlePath
        }
        if launched.hasPrefix("/") { return launched }
        let real = (launched as NSString).standardizingPath
        if real.hasPrefix("/"), fileExists(real) { return real }
        if fileExists("/opt/homebrew/bin/barkvisor") { return "/opt/homebrew/bin/barkvisor" }
        return "/usr/local/bin/barkvisor"
    }

    #if os(macOS)
        public static func arm(target: String) throws {
            let helper = helperPath(target: target)
            let script = helperScript(
                binary: binaryPath(),
                seconds: HostNetworkPendingCommitService.rollbackSeconds,
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: helper).deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try script.write(toFile: helper, atomically: true, encoding: .utf8)
            _ = try? PlatformProcess.run(path: "/bin/chmod", arguments: ["0755", helper], timeout: 5)
            let plist = plistURL(target: target)
            try plistXML(target: target, helperPath: helper)
                .write(to: plist, atomically: true, encoding: .utf8)
            _ = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: SocketVmnetLaunchd.bootoutArguments(label: label(target: target)),
                timeout: 15,
            )
            let result = try PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: SocketVmnetLaunchd.bootstrapArguments(plistPath: plist.path),
                timeout: 15,
            )
            if !result.succeeded {
                throw BarkVisorError.internalError(
                    "Could not arm \(HostNetworkPendingCommitService.rollbackSeconds)s Mac revert timer: \(result.stderrString)",
                )
            }
        }

        public static func disarm(target: String) {
            _ = try? PlatformProcess.run(
                path: "/bin/launchctl",
                arguments: SocketVmnetLaunchd.bootoutArguments(label: label(target: target)),
                timeout: 15,
            )
            try? FileManager.default.removeItem(at: plistURL(target: target))
            try? FileManager.default.removeItem(atPath: helperPath(target: target))
        }
    #endif
}
