import BarkVisorHelperProtocol
import Foundation

class HelperHandler: NSObject, HelperProtocol {
    func getVersion(reply: @escaping (String) -> Void) {
        reply("1.0.0")
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("Hello from BarkVisorHelper!")
    }

    // MARK: - Bridge Management

    func installBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        guard validateInterface(interface) else {
            reply(false, "Invalid interface name: must be alphanumeric, max 15 chars")
            return
        }

        let (resolvedVmnet, searchedPaths) = resolveSocketVmnet()
        guard let vmnetBinPath = resolvedVmnet else {
            reply(false, "socket_vmnet not found. Searched: \(searchedPaths.joined(separator: ", "))")
            return
        }

        let limaPrefix = "io.github.lima-vm.socket_vmnet.bridged."
        let limaPlist = "/Library/LaunchDaemons/\(limaPrefix)\(interface).plist"
        if FileManager.default.fileExists(atPath: limaPlist) {
            reply(
                false,
                "A bridge for \(interface) already exists (\(limaPrefix)\(interface)). Remove it first.",
            )
            return
        }

        let label = "dev.barkvisor.socket_vmnet.bridged.\(interface)"
        let socketPath = "/var/run/socket_vmnet.bridged.\(interface)"
        let plistPath = "/Library/LaunchDaemons/\(label).plist"
        let logDir = "/var/log/barkvisor"

        let plistData: Data
        do {
            plistData = try buildBridgePlist(
                label: label, vmnetBinPath: vmnetBinPath, interface: interface,
                socketPath: socketPath, logDir: logDir,
            )
        } catch {
            reply(false, "Failed to serialize plist: \(error.localizedDescription)")
            return
        }

        if let writeError = writePlistAtomically(
            plistData: plistData, plistPath: plistPath, logDir: logDir, interface: interface,
        ) {
            reply(false, writeError)
            return
        }

        if let bootstrapError = bootstrapDaemon(
            label: label, plistPath: plistPath, interface: interface, logDir: logDir,
        ) {
            reply(false, bootstrapError)
            return
        }

        makeSocketAccessible(socketPath)
        reply(true, nil)
    }

    private func buildBridgePlist(
        label: String, vmnetBinPath: String, interface: String,
        socketPath: String, logDir: String,
    ) throws -> Data {
        let plistDict: [String: Any] = [
            "Label": label,
            "Program": vmnetBinPath,
            "ProgramArguments": [
                vmnetBinPath,
                "--vmnet-mode=bridged",
                "--vmnet-interface=\(interface)",
                socketPath,
            ],
            "StandardErrorPath": "\(logDir)/socket_vmnet.bridged.\(interface).stderr",
            "StandardOutPath": "\(logDir)/socket_vmnet.bridged.\(interface).stdout",
            "RunAtLoad": true,
            "KeepAlive": true,
            "UserName": "root",
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plistDict, format: .xml, options: 0,
        )
    }

    private func writePlistAtomically(
        plistData: Data, plistPath: String, logDir: String, interface: String,
    ) -> String? {
        let parentDir = (plistPath as NSString).deletingLastPathComponent
        if isSymlink(atPath: parentDir) {
            return "Refusing to write: parent directory \(parentDir) is a symlink"
        }

        do {
            try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        } catch {
            return "Failed to create log directory: \(error.localizedDescription)"
        }

        let fd = open(plistPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            let err = errno
            if err == EEXIST {
                return
                    "A bridge for \(interface) already exists (dev.barkvisor.socket_vmnet.bridged.\(interface)). Remove it first."
            }
            return "Failed to create plist at \(plistPath): \(String(cString: strerror(err)))"
        }
        let written = plistData.withUnsafeBytes { buf -> Bool in
            guard let ptr = buf.baseAddress else { return false }
            var remaining = plistData.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, ptr.advanced(by: offset), remaining)
                if n < 0 { return false }
                offset += n
                remaining -= n
            }
            return true
        }
        close(fd)
        guard written else {
            unlink(plistPath)
            return "Failed to write plist data to \(plistPath)"
        }
        return nil
    }

    private func bootstrapDaemon(
        label: String, plistPath: String, interface: String, logDir: String,
    ) -> String? {
        runProcess("/bin/launchctl", arguments: ["bootout", "system/\(label)"])

        let (success, output) = runProcess(
            "/bin/launchctl", arguments: ["bootstrap", "system", plistPath],
        )
        if !success {
            return "launchctl bootstrap failed: \(output)"
        }

        Thread.sleep(forTimeInterval: 2)
        BridgeMonitor.shared.rescan()
        let daemonRunning =
            BridgeMonitor.shared.cachedStates
                .first { $0.interface == interface }?.daemonRunning ?? false
        if !daemonRunning {
            let stderrPath = "\(logDir)/socket_vmnet.bridged.\(interface).stderr"
            let stderrContent = (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
            let lastLines = stderrContent.components(separatedBy: "\n").suffix(5).joined(
                separator: "\n",
            )
            return "Bridge daemon for \(interface) failed to start. Log: \(lastLines)"
        }

        return nil
    }

    func removeBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        guard validateInterface(interface) else {
            reply(false, "Invalid interface name")
            return
        }

        // Only remove bridges managed by BarkVisor
        let knownPrefixes = ["dev.barkvisor.socket_vmnet.bridged."]
        var errors: [String] = []

        for prefix in knownPrefixes {
            let label = "\(prefix)\(interface)"
            let plistPath = "/Library/LaunchDaemons/\(label).plist"

            if FileManager.default.fileExists(atPath: plistPath) {
                // Reject symlinks — removing a symlink target by accident is not
                // as dangerous as writing through one, but still unexpected.
                if isSymlink(atPath: plistPath) {
                    errors.append("Refusing to remove \(plistPath): path is a symlink")
                    continue
                }
                runProcess("/bin/launchctl", arguments: ["bootout", "system/\(label)"])
                do {
                    try FileManager.default.removeItem(atPath: plistPath)
                } catch {
                    errors.append("Failed to remove \(plistPath): \(error.localizedDescription)")
                }
            }
        }

        // Clean up stale socket files
        let socketPaths = [
            "/var/run/socket_vmnet.bridged.\(interface)",
            "/opt/homebrew/var/run/socket_vmnet.bridged.\(interface)",
        ]
        for sp in socketPaths where FileManager.default.fileExists(atPath: sp) {
            try? FileManager.default.removeItem(atPath: sp)
        }

        // Rescan so DB gets updated immediately
        BridgeMonitor.shared.rescan()

        if errors.isEmpty {
            reply(true, nil)
        } else {
            reply(false, errors.joined(separator: "; "))
        }
    }

    func startBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        guard validateInterface(interface) else {
            reply(false, "Invalid interface name")
            return
        }

        let label = "dev.barkvisor.socket_vmnet.bridged.\(interface)"
        let plistPath = "/Library/LaunchDaemons/\(label).plist"

        guard FileManager.default.fileExists(atPath: plistPath) else {
            reply(false, "No plist found for \(interface) — install the bridge first")
            return
        }

        // Bootout first in case it's in a stuck/loaded state
        runProcess("/bin/launchctl", arguments: ["bootout", "system/\(label)"])

        let (success, output) = runProcess(
            "/bin/launchctl", arguments: ["bootstrap", "system", plistPath],
        )
        if !success {
            reply(false, "launchctl bootstrap failed: \(output)")
            return
        }

        Thread.sleep(forTimeInterval: 2)
        BridgeMonitor.shared.rescan()

        let daemonRunning =
            BridgeMonitor.shared.cachedStates
                .first { $0.interface == interface }?.daemonRunning ?? false
        if !daemonRunning {
            let stderrPath = "/var/log/barkvisor/socket_vmnet.bridged.\(interface).stderr"
            let stderrContent = (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
            let lastLines = stderrContent.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
            reply(false, "Bridge daemon for \(interface) failed to start. Log: \(lastLines)")
            return
        }

        // Allow the _barkvisor service user to connect to the socket
        let socketPath = "/var/run/socket_vmnet.bridged.\(interface)"
        makeSocketAccessible(socketPath)

        reply(true, nil)
    }

    func stopBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        guard validateInterface(interface) else {
            reply(false, "Invalid interface name")
            return
        }

        let label = "dev.barkvisor.socket_vmnet.bridged.\(interface)"
        let plistPath = "/Library/LaunchDaemons/\(label).plist"

        guard FileManager.default.fileExists(atPath: plistPath) else {
            reply(false, "No bridge installed for \(interface)")
            return
        }

        let (success, output) = runProcess("/bin/launchctl", arguments: ["bootout", "system/\(label)"])
        if !success {
            // Not an error if it wasn't loaded
            let alreadyStopped =
                output.contains("Could not find specified service") || output.contains("No such process")
            if !alreadyStopped {
                reply(false, "launchctl bootout failed: \(output)")
                return
            }
        }

        // Wait for the process to exit and the socket to disappear.
        // launchctl bootout can take a few seconds to fully tear down.
        let socketPaths = [
            "/var/run/socket_vmnet.bridged.\(interface)",
            "/opt/homebrew/var/run/socket_vmnet.bridged.\(interface)",
        ]
        let fm = FileManager.default

        for _ in 0 ..< 50 { // up to 5s
            BridgeMonitor.shared.rescan()
            let state = BridgeMonitor.shared.cachedStates
                .first { $0.interface == interface }
            let stillRunning = state?.daemonRunning ?? false
            let socketExists = socketPaths.contains { fm.fileExists(atPath: $0) }
            if !stillRunning, !socketExists { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Clean up stale socket files that socket_vmnet may leave behind
        for path in socketPaths where fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }

        BridgeMonitor.shared.rescan()
        reply(true, nil)
    }

    func bridgeStatus(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        guard validateInterface(interface) else {
            reply(false, "Invalid interface name")
            return
        }

        let label = "dev.barkvisor.socket_vmnet.bridged.\(interface)"
        let plistPath = "/Library/LaunchDaemons/\(label).plist"

        let plistExists = FileManager.default.fileExists(atPath: plistPath)
        let daemonRunning =
            BridgeMonitor.shared.cachedStates
                .first { $0.interface == interface }?.daemonRunning ?? false

        if daemonRunning {
            reply(true, "running")
        } else if plistExists {
            reply(true, "installed")
        } else {
            reply(false, "not_installed")
        }
    }

    // MARK: - All Bridge States

    func getAllBridgeStates(reply: @escaping (String) -> Void) {
        BridgeMonitor.shared.rescan()
        let states = BridgeMonitor.shared.cachedStates
        let data = try? JSONEncoder().encode(states)
        reply(data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
    }

    // MARK: - Software Update

    func installUpdate(
        packagePath: String,
        expectedVersion: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        // 1. Validate package path exists and is not a symlink
        guard FileManager.default.fileExists(atPath: packagePath) else {
            reply(false, "Package file not found at \(packagePath)")
            return
        }
        if isSymlink(atPath: packagePath) {
            reply(false, "Refusing to install: package path is a symlink")
            return
        }

        // 2. Verify PKG code signature
        let (sigOk, sigOutput) = runProcess(
            "/usr/sbin/pkgutil",
            arguments: ["--check-signature", packagePath],
        )
        if !sigOk {
            reply(false, "Package signature verification failed: \(sigOutput)")
            return
        }

        // Verify signing team ID matches our known team ID
        // pkgutil output contains lines like: "Developer ID Installer: Name (TEAM_ID)"
        let teamIDPattern = "\\(([A-Z0-9]+)\\)"
        if let range = sigOutput.range(of: teamIDPattern, options: .regularExpression) {
            let match = sigOutput[range]
            let extractedID = String(match.dropFirst().dropLast()) // Remove parentheses
            if extractedID != kHelperTeamID {
                reply(
                    false, "Package signed by unexpected team ID: \(extractedID) (expected \(kHelperTeamID))",
                )
                return
            }
        } else {
            reply(false, "Could not extract team ID from package signature")
            return
        }

        // 3. Verify Apple notarization
        let (notarizeOk, notarizeOutput) = runProcess(
            "/usr/sbin/spctl",
            arguments: ["-a", "-t", "install", packagePath],
        )
        if !notarizeOk {
            reply(false, "Package notarization check failed: \(notarizeOutput)")
            return
        }

        // 4. All checks passed — reply now, before the installer kills this process.
        //    The postinstall script runs `launchctl bootout` on the helper daemon,
        //    so any code after a synchronous installer call would never execute.
        reply(true, nil)

        // Run the installer asynchronously after a short delay so the XPC reply
        // is delivered before the postinstall script kills this daemon.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
            proc.arguments = ["-pkg", packagePath, "-target", "/"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                // This code only runs if the process survives (non-self-update PKG).
                try? FileManager.default.removeItem(atPath: packagePath)
                if proc.terminationStatus != 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    NSLog("BarkVisor: installer failed after reply: \(output)")
                }
            } catch {
                NSLog("BarkVisor: failed to launch installer: \(error)")
            }
        }
    }
}
