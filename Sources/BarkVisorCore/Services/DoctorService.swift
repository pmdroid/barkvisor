#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// One read-only Device check. Status is gated by privilege (root vs unprivileged).
public struct DoctorCheck: Codable, Sendable, Equatable {
    public var id: String
    public var status: DoctorCheckStatus
    public var detail: String

    public init(id: String, status: DoctorCheckStatus, detail: String) {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

public enum DoctorCheckStatus: String, Codable, Sendable, Equatable {
    case ok
    case warn
    case fail
    case skip
}

/// Read-only doctor report. `hostBridge` is the existing HostBridgeReadiness model.
public struct DoctorReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var privileged: Bool
    public var checks: [DoctorCheck]
    public var hostBridge: HostBridgeReadiness

    public init(
        ok: Bool,
        privileged: Bool,
        checks: [DoctorCheck],
        hostBridge: HostBridgeReadiness,
    ) {
        self.ok = ok
        self.privileged = privileged
        self.checks = checks
        self.hostBridge = hostBridge
    }
}

public struct DoctorProcess: Sendable, Equatable {
    public var pid: Int32
    public var uid: UInt32
    public var command: String

    public init(pid: Int32, uid: UInt32, command: String) {
        self.pid = pid
        self.uid = uid
        self.command = command
    }
}

/// Injected probe inputs. Tests pass this; live host uses `LiveDoctorFactSource`.
public struct DoctorFactInputs: Sendable, Equatable {
    public var os: String
    public var uid: UInt32
    public var qemuPath: String?
    public var qemuProcesses: [DoctorProcess]
    public var kvmPresent: Bool
    public var kvmAccessible: Bool
    public var swtpmPath: String?
    public var swtpmRequired: Bool
    public var healthURL: String
    public var healthOK: Bool
    public var healthDetail: String
    public var hostBridge: HostBridgeReadiness
    public var suggestedBridgeAddress: String?
    public var macSocketServiceRunning: Bool

    public init(
        os: String,
        uid: UInt32,
        qemuPath: String? = nil,
        qemuProcesses: [DoctorProcess] = [],
        kvmPresent: Bool = false,
        kvmAccessible: Bool = false,
        swtpmPath: String? = nil,
        swtpmRequired: Bool = true,
        healthURL: String = "http://127.0.0.1:7777/api/health",
        healthOK: Bool = false,
        healthDetail: String = "not probed",
        hostBridge: HostBridgeReadiness,
        suggestedBridgeAddress: String? = nil,
        macSocketServiceRunning: Bool = false,
    ) {
        self.os = os
        self.uid = uid
        self.qemuPath = qemuPath
        self.qemuProcesses = qemuProcesses
        self.kvmPresent = kvmPresent
        self.kvmAccessible = kvmAccessible
        self.swtpmPath = swtpmPath
        self.swtpmRequired = swtpmRequired
        self.healthURL = healthURL
        self.healthOK = healthOK
        self.healthDetail = healthDetail
        self.hostBridge = hostBridge
        self.suggestedBridgeAddress = suggestedBridgeAddress
        self.macSocketServiceRunning = macSocketServiceRunning
    }
}

public protocol DoctorFactSource: Sendable {
    func inputs() -> DoctorFactInputs
}

/// Live host probes. Read-only: never installs, starts, stops, or writes.
public struct LiveDoctorFactSource: DoctorFactSource {
    public init() {}

    public func inputs() -> DoctorFactInputs {
        let qemuName = DoctorService.qemuBinaryName()
        let qemuPath = (try? BundleResolver.helper(qemuName))?.path
        let processes = DoctorProcessList.live()
        let qemuProcesses = processes.filter { $0.command.contains("qemu-system") }
        let healthURL = DoctorService.healthURL()
        let health = DoctorHealthClient.get(url: healthURL)
        let facts = HostBridgeFactsService.probe()
        let suggested = facts.suggestedBridge
        let address = HostInfoService.listInterfaces()
            .first { $0.name == suggested }?.ipAddress
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DoctorFactInputs(
            os: PlatformHost.platformName,
            uid: DoctorDaemonProcess.uid(from: processes, fallback: UInt32(geteuid())),
            qemuPath: qemuPath,
            qemuProcesses: qemuProcesses,
            kvmPresent: HostInventoryService.kvmDevicePresent(),
            kvmAccessible: FileManager.default.isReadableFile(atPath: "/dev/kvm"),
            swtpmPath: (try? BundleResolver.helper("swtpm"))?.path,
            swtpmRequired: DoctorService.swtpmRequired(),
            healthURL: healthURL.absoluteString,
            healthOK: health.ok,
            healthDetail: health.detail,
            hostBridge: facts.readiness,
            suggestedBridgeAddress: trimmed.isEmpty ? nil : trimmed,
            macSocketServiceRunning: processes.contains { $0.command.contains("socket_vmnet") },
        )
    }
}

/// Read-only Device capability checks. CLI and `GET /api/system/doctor` share this.
public enum DoctorService {
    public static func qemuBinaryName(hostArch: String = PlatformCapabilities.hostArch) -> String {
        let profileID = GuestProfiles.defaultLinuxID(forImageArch: hostArch)
        if let name = GuestProfiles.profile(for: profileID)?.qemuBinaryName {
            return name
        }
        return "qemu-system-\(PlatformCapabilities.defaultGuestArch)"
    }

    public static func swtpmRequired(hostArch: String = PlatformCapabilities.hostArch) -> Bool {
        GuestProfiles.profilesCompatible(withHostArch: hostArch).contains { $0.defaultTPMEnabled }
    }

    public static func healthURL(port: Int = Config.port) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/api/health"
        if let url = components.url {
            return url
        }
        return URL(fileURLWithPath: "/api/health")
    }

    public static func probe(source: any DoctorFactSource = LiveDoctorFactSource()) -> DoctorReport {
        assemble(from: source.inputs())
    }

    public static func assemble(from inputs: DoctorFactInputs) -> DoctorReport {
        let privileged = inputs.uid == 0
        let checks = [
            daemonUIDCheck(inputs),
            qemuCheck(inputs),
            qemuProcessCheck(inputs),
            kvmCheck(inputs),
            swtpmCheck(inputs),
            healthCheck(inputs),
            linuxBridgeCheck(inputs, privileged: privileged),
            macSocketCheck(inputs, privileged: privileged),
        ]
        return DoctorReport(
            ok: !checks.contains { $0.status == .fail },
            privileged: privileged,
            checks: checks,
            hostBridge: inputs.hostBridge,
        )
    }

    public static func jsonData(_ report: DoctorReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public static func renderText(_ report: DoctorReport) -> String {
        var lines = [
            "BarkVisor doctor",
            "ok=\(report.ok) privileged=\(report.privileged)",
            "",
        ]
        for check in report.checks {
            let pad = String(repeating: " ", count: max(0, 8 - check.status.rawValue.count))
            lines.append("\(check.status.rawValue)\(pad)\(check.id)  \(check.detail)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Checks

    private static func daemonUIDCheck(_ inputs: DoctorFactInputs) -> DoctorCheck {
        if inputs.uid == 0 {
            return DoctorCheck(
                id: "daemon-uid",
                status: .ok,
                detail: "uid=0 (root). Appliance Device daemon.",
            )
        }
        return DoctorCheck(
            id: "daemon-uid",
            status: .warn,
            detail: "uid=\(inputs.uid) (unprivileged). Appliance Device expects root (#386).",
        )
    }

    private static func qemuCheck(_ inputs: DoctorFactInputs) -> DoctorCheck {
        if let path = inputs.qemuPath, !path.isEmpty {
            return DoctorCheck(id: "qemu", status: .ok, detail: path)
        }
        return DoctorCheck(
            id: "qemu",
            status: .fail,
            detail: "\(qemuBinaryName()) not found. \(PlatformQEMU.qemuInstallHint)",
        )
    }

    private static func qemuProcessCheck(_ inputs: DoctorFactInputs) -> DoctorCheck {
        let hvfNote =
            "macOS HVF guests inherit the Device daemon uid until #386; drop may not be possible with HVF."
        if inputs.qemuProcesses.isEmpty {
            let extra = isMacOS(inputs.os) ? " \(hvfNote)" : ""
            return DoctorCheck(
                id: "qemu-process",
                status: .skip,
                detail: "No Workload QEMU process.\(extra)",
            )
        }
        let rooted = inputs.qemuProcesses.filter { $0.uid == 0 }
        if rooted.isEmpty {
            let parts = inputs.qemuProcesses.map { "pid \($0.pid) uid=\($0.uid)" }
            return DoctorCheck(
                id: "qemu-process",
                status: .ok,
                detail: "Workload QEMU dropped: \(parts.joined(separator: ", ")).",
            )
        }
        let parts = rooted.map { "pid \($0.pid)" }
        var detail =
            "Workload QEMU \(parts.joined(separator: ", ")) is uid=0 (root). Prefer drop to barkvisor/qemu after #386."
        if isMacOS(inputs.os) {
            detail += " \(hvfNote)"
        }
        return DoctorCheck(id: "qemu-process", status: .warn, detail: detail)
    }

    private static func kvmCheck(_ inputs: DoctorFactInputs) -> DoctorCheck {
        if !isLinux(inputs.os) {
            return DoctorCheck(
                id: "kvm",
                status: .skip,
                detail: "Not used on \(inputs.os) (HVF).",
            )
        }
        if !inputs.kvmPresent {
            return DoctorCheck(
                id: "kvm",
                status: .fail,
                detail: "/dev/kvm is missing. Linux Workloads expect KVM.",
            )
        }
        if !inputs.kvmAccessible {
            return DoctorCheck(
                id: "kvm",
                status: .warn,
                detail: "/dev/kvm exists but is not readable.",
            )
        }
        return DoctorCheck(id: "kvm", status: .ok, detail: "/dev/kvm is present.")
    }

    private static func swtpmCheck(_ inputs: DoctorFactInputs) -> DoctorCheck {
        if let path = inputs.swtpmPath, !path.isEmpty {
            return DoctorCheck(id: "swtpm", status: .ok, detail: path)
        }
        if !inputs.swtpmRequired {
            return DoctorCheck(
                id: "swtpm",
                status: .skip,
                detail: "swtpm is not required on this Device.",
            )
        }
        return DoctorCheck(
            id: "swtpm",
            status: .fail,
            detail: "swtpm not found. Windows Workloads need TPM 2.0 emulation. \(PlatformQEMU.swtpmInstallHint)",
        )
    }

    private static func healthCheck(_ inputs: DoctorFactInputs) -> DoctorCheck {
        if inputs.healthOK {
            return DoctorCheck(
                id: "api-health",
                status: .ok,
                detail: "GET \(inputs.healthURL) \(inputs.healthDetail)",
            )
        }
        return DoctorCheck(
            id: "api-health",
            status: .fail,
            detail: "GET \(inputs.healthURL) failed: \(inputs.healthDetail)",
        )
    }

    private static func linuxBridgeCheck(
        _ inputs: DoctorFactInputs,
        privileged: Bool,
    ) -> DoctorCheck {
        if !isLinux(inputs.os) {
            return DoctorCheck(
                id: "linux-bridge",
                status: .skip,
                detail: "\(inputs.os) uses socket_vmnet, not qemu-bridge-helper.",
            )
        }
        let ready = inputs.hostBridge
        let helper = ready.helperPath ?? HostBridgeFactsService.qemuBridgeHelperCandidates[0]
        let address = inputs.suggestedBridgeAddress ?? "none"
        let acl: String = if let allowed = ready.aclAllowsSuggested {
            allowed ? "allow \(ready.suggestedBridge)" : "deny"
        } else {
            "missing"
        }
        let summary =
            "\(ready.suggestedBridge) address=\(address) helper=\(helper) setuid=\(ready.helperSetuid) acl=\(acl) ready=\(ready.ready)"
        if ready.ready, inputs.suggestedBridgeAddress != nil {
            return DoctorCheck(id: "linux-bridge", status: .ok, detail: summary)
        }
        if ready.ready {
            return DoctorCheck(
                id: "linux-bridge",
                status: .warn,
                detail: "\(summary). \(ready.suggestedBridge) has no IPv4 address.",
            )
        }
        return DoctorCheck(
            id: "linux-bridge",
            status: privileged ? .fail : .warn,
            detail: "\(summary). Copy Bridge setup steps; doctor never applies them.",
        )
    }

    private static func macSocketCheck(
        _ inputs: DoctorFactInputs,
        privileged: Bool,
    ) -> DoctorCheck {
        if !isMacOS(inputs.os) {
            return DoctorCheck(
                id: "macos-socket-vmnet",
                status: .skip,
                detail: "\(inputs.os) uses a host bridge, not socket_vmnet.",
            )
        }
        let ready = inputs.hostBridge
        let sockets = ready.bridges.map(\.name)
        let names = sockets.isEmpty ? "none" : sockets.joined(separator: ", ")
        let summary =
            "socket=\(ready.ready) service=\(inputs.macSocketServiceRunning) uplink=\(names)"
        if ready.ready {
            return DoctorCheck(id: "macos-socket-vmnet", status: .ok, detail: summary)
        }
        return DoctorCheck(
            id: "macos-socket-vmnet",
            status: privileged ? .fail : .warn,
            detail: "\(summary). \(SocketVmnetDiscovery.installHint). Doctor never starts the service.",
        )
    }

    private static func isLinux(_ os: String) -> Bool {
        os.caseInsensitiveCompare("Linux") == .orderedSame
    }

    private static func isMacOS(_ os: String) -> Bool {
        os.caseInsensitiveCompare("macOS") == .orderedSame
    }
}

enum DoctorHealthClient {
    static func get(url: URL, timeout: TimeInterval = 2) -> (ok: Bool, detail: String) {
        let box = HealthBox()
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { sem.signal() }
            if let error {
                box.set(false, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.set(false, "non-HTTP response")
                return
            }
            box.set((200 ..< 300).contains(http.statusCode), "HTTP \(http.statusCode)")
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return (false, "timeout")
        }
        return box.get()
    }

    private final class HealthBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Bool, String) = (false, "no response")

        func set(_ ok: Bool, _ detail: String) {
            lock.lock()
            value = (ok, detail)
            lock.unlock()
        }

        func get() -> (Bool, String) {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}

enum DoctorProcessList {
    static func live() -> [DoctorProcess] {
        let result = try? PlatformProcess.run(
            path: "/bin/ps",
            arguments: ["-axo", "pid=", "uid=", "command="],
            timeout: 5,
        )
        guard let result, result.succeeded else { return [] }
        return parse(result.stdoutString)
    }

    static func parse(_ text: String) -> [DoctorProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let uid = UInt32(parts[1])
            else { return nil }
            return DoctorProcess(pid: pid, uid: uid, command: String(parts[2]))
        }
    }
}

/// Device daemon rows from `ps`. Excludes CLI `doctor` / `join`.
enum DoctorDaemonProcess {
    static func matches(_ command: String) -> Bool {
        let parts = command.split(whereSeparator: \.isWhitespace)
        guard let argv0 = parts.first else { return false }
        let name = URL(fileURLWithPath: String(argv0)).lastPathComponent
        guard name == "barkvisor" || name == "barkvisor-agent" else { return false }
        guard let first = parts.dropFirst().first else { return true }
        let arg = String(first)
        if arg.hasPrefix("-") { return true }
        return arg == "serve"
    }

    static func uid(from processes: [DoctorProcess], fallback: UInt32) -> UInt32 {
        processes.first { matches($0.command) }?.uid ?? fallback
    }
}
