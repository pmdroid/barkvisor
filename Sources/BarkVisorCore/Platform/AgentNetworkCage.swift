import Foundation

/// LAN / host-loopback block for Agent-class NAT (PAS-268).
///
/// Slirp NAT is not on the house L2, but the guest can still originate TCP to
/// RFC1918 and to the daemon via 10.0.2.2. This type:
/// 1. Black-holes guest connections to the daemon ports on the slirp gateway.
/// 2. Wraps QEMU in a Mac seatbelt that denies RFC1918 / loopback outbound
///    (DNS/53 still allowed so slirp can resolve).
/// 3. On Linux, inserts iptables owner-match REJECT rules for the QEMU pid.
public enum AgentNetworkCage {
    public static let slirpGateway = "10.0.2.2"

    /// Device-local Ollama (PAS-271). Guest reaches it at 10.0.2.2:11434.
    public static let ollamaPort = 11_434

    public static let blockedIPv4CIDRs = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "127.0.0.0/8",
        "100.64.0.0/10",
        "224.0.0.0/4",
    ]

    public static var hostServicePorts: [Int] {
        [Config.port, Config.agentPort]
    }

    /// Device Ollama guestfwd/seatbelt/iptables exception. Opt-in via cloud-init
    /// that names `10.0.2.2:11434` (Coding Agent Device-Ollama preset). Other
    /// Agent-class NAT Workloads keep the loopback black-hole.
    public static func allowHostOllama(userData: String?) -> Bool {
        guard let userData, !userData.isEmpty else { return false }
        return userData.contains("\(slirpGateway):\(ollamaPort)")
    }

    /// Extra `-netdev user` suffixes for Agent NAT (not isolated).
    public static func slirpExtras(mode: NetworkMode, allowHostOllama: Bool = false) -> String {
        guard mode == .nat else { return "" }
        var extra = ",ipv6=off"
        for port in hostServicePorts {
            extra += ",guestfwd=tcp:\(slirpGateway):\(port)-cmd:true"
        }
        if allowHostOllama {
            extra += ",guestfwd=tcp:\(slirpGateway):\(ollamaPort)-tcp:127.0.0.1:\(ollamaPort)"
        }
        return extra
    }

    public static func wrapLaunch(
        _ launch: QEMULaunchConfig,
        workloadClass: WorkloadClass,
        allowHostOllama: Bool = false,
    ) throws -> QEMULaunchConfig {
        guard workloadClass == .agent else { return launch }
        #if os(macOS)
            let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            guard FileManager.default.isExecutableFile(atPath: sandbox.path) else {
                throw BarkVisorError.forbidden(
                    "Agent Workloads need sandbox-exec to block the house LAN",
                )
            }
            return QEMULaunchConfig(
                executable: sandbox,
                arguments: [
                    "-p", seatbeltProfile(allowHostOllama: allowHostOllama),
                    launch.executable.path,
                ] + launch.arguments,
                swtpmExecutable: launch.swtpmExecutable,
                swtpmArguments: launch.swtpmArguments,
                swtpmStateDir: launch.swtpmStateDir,
            )
        #else
            _ = allowHostOllama
            return launch
        #endif
    }

    /// Seatbelt: allow everything, then deny private/loopback outbound except DNS.
    public static var seatbeltProfile: String {
        seatbeltProfile(allowHostOllama: false)
    }

    public static func seatbeltProfile(allowHostOllama: Bool) -> String {
        var profile = """
        (version 1)
        (allow default)
        (allow network-outbound (remote udp "*:53"))
        (allow network-outbound (remote tcp "*:53"))
        (deny network-outbound (remote ip "10.0.0.0/8"))
        (deny network-outbound (remote ip "172.16.0.0/12"))
        (deny network-outbound (remote ip "192.168.0.0/16"))
        (deny network-outbound (remote ip "169.254.0.0/16"))
        (deny network-outbound (remote ip "127.0.0.0/8"))
        (deny network-outbound (remote ip "100.64.0.0/10"))
        (deny network-outbound (remote ip "224.0.0.0/4"))
        """
        if allowHostOllama {
            profile += "(allow network-outbound (remote tcp \"127.0.0.1:11434\"))\n"
        }
        return profile
    }

    public static func linuxOwnerRejectCommands(pid: Int32) -> [[String]] {
        linuxOwnerCommands(pid: pid, action: "-I")
    }

    public static func linuxOwnerDeleteCommands(pid: Int32) -> [[String]] {
        linuxOwnerCommands(pid: pid, action: "-D")
    }

    public static let iptablesSearchPaths = [
        "/usr/sbin/iptables",
        "/sbin/iptables",
        "/usr/bin/iptables",
        "/usr/local/sbin/iptables",
    ]

    public static func resolveIptables() -> URL? {
        iptablesSearchPaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func applyLinuxFilter(pid: Int32, vmID: String) throws {
        #if os(Linux)
            guard let exe = resolveIptables() else {
                throw BarkVisorError.forbidden(
                    "Agent Workloads need iptables to block the house LAN",
                )
            }
            try runIptables(exe: exe, commands: linuxOwnerRejectCommands(pid: pid), vmID: vmID)
            if allowHostOllama(userData: CloudInitService.storedUserData(vmID: vmID)) {
                try runIptables(exe: exe, commands: linuxOllamaAcceptCommands(pid: pid), vmID: vmID)
            }
            Log.vm.info("Agent LAN filter applied for pid \(pid)", vm: vmID)
        #else
            _ = pid
            _ = vmID
        #endif
    }

    public static func removeLinuxFilter(pid: Int32, vmID: String) {
        #if os(Linux)
            guard let exe = resolveIptables() else { return }
            for args in linuxOllamaDeleteCommands(pid: pid) + linuxOwnerDeleteCommands(pid: pid) {
                let proc = Process()
                proc.executableURL = exe
                proc.arguments = Array(args.dropFirst())
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
            Log.vm.info("Agent LAN filter removed for pid \(pid)", vm: vmID)
        #else
            _ = pid
            _ = vmID
        #endif
    }

    private static func linuxOwnerCommands(pid: Int32, action: String) -> [[String]] {
        blockedIPv4CIDRs.map { cidr in
            [
                "iptables", action, "OUTPUT",
                "-m", "owner", "--pid-owner", "\(pid)",
                "-d", cidr,
                "-j", "REJECT",
            ]
        }
    }

    public static func linuxOllamaAcceptCommands(pid: Int32) -> [[String]] {
        linuxOllamaCommands(pid: pid, action: "-I")
    }

    public static func linuxOllamaDeleteCommands(pid: Int32) -> [[String]] {
        linuxOllamaCommands(pid: pid, action: "-D")
    }

    private static func linuxOllamaCommands(pid: Int32, action: String) -> [[String]] {
        [[
            "iptables", action, "OUTPUT",
            "-m", "owner", "--pid-owner", "\(pid)",
            "-p", "tcp",
            "-d", "127.0.0.1",
            "--dport", "\(ollamaPort)",
            "-j", "ACCEPT",
        ]]
    }

    #if os(Linux)
        private static func runIptables(exe: URL, commands: [[String]], vmID: String) throws {
            for args in commands {
                let proc = Process()
                proc.executableURL = exe
                proc.arguments = Array(args.dropFirst())
                let err = Pipe()
                proc.standardError = err
                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    throw BarkVisorError.forbidden(
                        "Agent LAN filter failed to start: \(error.localizedDescription)",
                    )
                }
                if proc.terminationStatus != 0 {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                        ?? "iptables failed"
                    throw BarkVisorError.forbidden("Agent LAN filter failed: \(msg)")
                }
            }
            _ = vmID
        }
    #endif
}
