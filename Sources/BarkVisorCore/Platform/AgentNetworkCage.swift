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

    /// Extra `-netdev user` suffixes for Agent NAT (not isolated).
    public static func slirpExtras(mode: NetworkMode) -> String {
        guard mode == .nat else { return "" }
        var extra = ",ipv6=off"
        for port in hostServicePorts {
            extra += ",guestfwd=tcp:\(slirpGateway):\(port)-cmd:true"
        }
        return extra
    }

    public static func wrapLaunch(
        _ launch: QEMULaunchConfig,
        workloadClass: WorkloadClass,
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
                arguments: ["-p", seatbeltProfile, launch.executable.path] + launch.arguments,
                swtpmExecutable: launch.swtpmExecutable,
                swtpmArguments: launch.swtpmArguments,
                swtpmStateDir: launch.swtpmStateDir,
            )
        #else
            return launch
        #endif
    }

    /// Seatbelt: allow everything, then deny private/loopback outbound except DNS.
    public static let seatbeltProfile = """
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

    public static func linuxOwnerRejectCommands(pid: Int32) -> [[String]] {
        blockedIPv4CIDRs.map { cidr in
            [
                "iptables", "-I", "OUTPUT",
                "-m", "owner", "--pid-owner", "\(pid)",
                "-d", cidr,
                "-j", "REJECT",
            ]
        }
    }

    public static func applyLinuxFilter(pid: Int32, vmID: String) throws {
        #if os(Linux)
            let iptables = URL(fileURLWithPath: "/usr/sbin/iptables")
            let exe = FileManager.default.isExecutableFile(atPath: iptables.path)
                ? iptables
                : URL(fileURLWithPath: "/sbin/iptables")
            guard FileManager.default.isExecutableFile(atPath: exe.path) else {
                throw BarkVisorError.forbidden(
                    "Agent Workloads need iptables to block the house LAN",
                )
            }
            for args in linuxOwnerRejectCommands(pid: pid) {
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
            Log.vm.info("Agent LAN filter applied for pid \(pid)", vm: vmID)
        #else
            _ = pid
            _ = vmID
        #endif
    }
}
