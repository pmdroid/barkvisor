import Foundation

struct BridgeState: Codable {
    let interface: String
    let socketPath: String?
    let plistExists: Bool
    let daemonRunning: Bool
    let status: String // "active", "installed", "not_configured"
}

final class BridgeMonitor: @unchecked Sendable {
    static let shared = BridgeMonitor()

    private let lock = NSLock()
    private var _cachedStates: [BridgeState] = []
    private var timer: DispatchSourceTimer?

    var cachedStates: [BridgeState] {
        lock.lock()
        defer { lock.unlock() }
        return _cachedStates
    }

    func start() {
        // Run initial scan synchronously so state is available immediately
        scan()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.scan()
        }
        timer.resume()
        self.timer = timer
    }

    /// Force an immediate rescan (e.g. after install/remove).
    func rescan() {
        scan()
    }

    private func scan() {
        var states: [BridgeState] = []
        let fm = FileManager.default
        let launchDaemonsPath = "/Library/LaunchDaemons"

        // Discover configured interfaces by scanning for matching plist files
        let prefix = "dev.barkvisor.socket_vmnet.bridged."

        var discoveredInterfaces = Set<String>()

        if let files = try? fm.contentsOfDirectory(atPath: launchDaemonsPath) {
            for file in files {
                guard file.hasSuffix(".plist") else { continue }
                let name = String(file.dropLast(6)) // remove .plist
                if name.hasPrefix(prefix) {
                    let iface = String(name.dropFirst(prefix.count))
                    if !iface.isEmpty {
                        discoveredInterfaces.insert(iface)
                    }
                }
            }
        }

        for iface in discoveredInterfaces.sorted() {
            let socketPaths = [
                "/var/run/socket_vmnet.bridged.\(iface)",
                "/opt/homebrew/var/run/socket_vmnet.bridged.\(iface)",
            ]
            let socketPath = socketPaths.first { fm.fileExists(atPath: $0) }

            let plistPath = "\(launchDaemonsPath)/dev.barkvisor.socket_vmnet.bridged.\(iface).plist"
            let plistExists = fm.fileExists(atPath: plistPath)

            let escapedIface = NSRegularExpression.escapedPattern(for: iface)
            let daemonRunning = isProcessRunning(matching: "socket_vmnet.*bridged\\.\(escapedIface)")

            let status =
                if daemonRunning {
                    "active"
                } else if plistExists || socketPath != nil {
                    "installed"
                } else {
                    "not_configured"
                }

            states.append(
                BridgeState(
                    interface: iface,
                    socketPath: socketPath,
                    plistExists: plistExists,
                    daemonRunning: daemonRunning,
                    status: status,
                ),
            )
        }

        lock.lock()
        _cachedStates = states
        lock.unlock()
    }

    private func isProcessRunning(matching pattern: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", pattern]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
