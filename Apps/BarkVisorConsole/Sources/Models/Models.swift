import Foundation

// MARK: - Product copy (docs/product-terminology.md)

enum Copy {
    static let home = "Home"
    static let device = "Device"
    static let devices = "Devices"
    static let workload = "Workload"
    static let workloads = "Workloads"
    static let library = "Library"
    static let emptyLibrary = LibraryCatalog.emptyLibraryCopy
}

// MARK: - Auth / setup

struct LoginRequest: Encodable {
    var username: String
    var password: String
}

struct LoginResponse: Decodable {
    var token: String
    var refreshToken: String
}

struct SessionTokens: Equatable {
    var token: String
    var refreshToken: String
}

struct RefreshRequest: Encodable {
    var refreshToken: String
}

struct LogoutRequest: Encodable {
    var refreshToken: String?
}

struct LoginRedeemRequest: Encodable {
    var code: String
}

struct LoginOfferIssueRequest: Encodable, Equatable {
    var advertisedHost: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let trimmed = advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            try container.encode(trimmed, forKey: .advertisedHost)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case advertisedHost
    }
}

struct LoginOfferIssue: Decodable, Hashable {
    var code: String
    var expiresAt: String
    var ttlSeconds: Int
    var uri: String
    var host: String
    var port: Int
}

struct SetupStatus: Decodable {
    var complete: Bool
    var joined: Bool?
}

struct APIErrorBody: Decodable {
    var error: Bool?
    var code: String?
    var reason: String?
    var status: Int?
}

// MARK: - Device (Home)

struct HomeDeviceList: Decodable {
    var devices: [HomeDevice]
}

struct HomeDevice: Decodable, Identifiable, Hashable {
    var hostId: String
    var role: String
    var fingerprint: String?
    var displayName: String?
    var agentHost: String?
    var agentPort: Int
    var pairedAt: String?

    var id: String {
        hostId
    }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }

    var isSelf: Bool {
        role == "self"
    }

    var asSnapshot: HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: role,
            displayName: displayName,
            fingerprint: fingerprint,
            agentHost: agentHost,
            agentPort: agentPort,
            pairedAt: pairedAt,
            reachability: "ok",
            reachabilityError: nil,
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
    }
}

struct HomeDevicePlatformSummary: Decodable, Hashable {
    var os: String
    var arch: String
}

struct HomeDeviceResourceSummary: Decodable, Hashable {
    var cpuCount: Int?
    var memoryTotalMB: Int?
    var memoryUsedMB: Int?
    var cpuLoadPercent: Double?
}

struct HomeDeviceHealthSnapshot: Decodable, Identifiable, Hashable {
    var hostId: String
    var role: String
    var displayName: String?
    var fingerprint: String?
    var agentHost: String?
    var agentPort: Int
    var pairedAt: String?
    var reachability: String
    var reachabilityError: String?
    var collectedAt: String?
    var platform: HomeDevicePlatformSummary?
    var resources: HomeDeviceResourceSummary?
    var workloadCount: Int?
    var healthCounts: [String: Int]?

    var id: String {
        hostId
    }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }

    var isSelf: Bool {
        role == "self"
    }
    var isReachable: Bool {
        reachability == "ok"
    }

    var reachabilityLabel: String {
        DeviceReachability.label(reachability)
    }

    var reachabilityStatusKey: String {
        DeviceReachability.statusKey(reachability)
    }

    static var placeholderSelf: HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: "self",
            role: "self",
            displayName: "Device",
            fingerprint: nil,
            agentHost: nil,
            agentPort: DeviceURL.defaultPort,
            pairedAt: nil,
            reachability: "ok",
            reachabilityError: nil,
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
    }

    var platformLabel: String {
        if let os = platform?.os, let arch = platform?.arch { return "\(os) · \(arch)" }
        if let os = platform?.os { return os }
        if let arch = platform?.arch { return arch }
        return isReachable ? Copy.device : "Unknown platform"
    }

    var workloadLine: String {
        if !isReachable { return "Health unavailable" }
        guard let count = workloadCount else { return "Workloads unknown" }
        let failed = healthCounts?["failed"] ?? 0
        if failed > 0 { return "\(count) workloads · \(failed) failed" }
        return count == 1 ? "1 workload" : "\(count) workloads"
    }

    /// CPU and memory from health. GPU occupancy is `gpu-devices`, not this line.
    var resourcesLine: String? {
        guard isReachable, let resources else { return nil }
        var parts: [String] = []
        if let cpu = resources.cpuLoadPercent {
            parts.append("CPU \(Int(cpu.rounded()))%")
        }
        if let used = resources.memoryUsedMB, let total = resources.memoryTotalMB {
            parts.append(String(format: "%.1f / %.0f GB", Double(used) / 1_024, Double(total) / 1_024))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// iOS Devices tab badge: count of paired Devices whose health is not reachable.
enum DevicesTabBadge {
    static func count(in devices: [HomeDeviceHealthSnapshot]) -> Int {
        devices.count(where: { !$0.isReachable })
    }
}

/// Health `reachability` codes from `GET /api/home/devices/health`.
enum DeviceReachability {
    static func label(_ code: String) -> String {
        switch code {
        case "ok": "Reachable"
        case "connectTimeout": "Timed out"
        case "cancelled": "Cancelled"
        case "tlsFailure": "TLS failed"
        case "memberHTTP": "HTTP error"
        default: "Unreachable"
        }
    }

    static func statusKey(_ code: String) -> String {
        switch code {
        case "ok": "reachable"
        case "memberHTTP": "degraded"
        case "connectTimeout", "cancelled", "tlsFailure": "failed"
        default: "unreachable"
        }
    }
}

struct HomeDeviceHealthTotals: Decodable, Hashable {
    var devices: Int
    var reachable: Int
    var unreachable: Int
    var workloadCount: Int?
    var healthCounts: [String: Int]
}

struct HomeDeviceHealthReport: Decodable, Hashable {
    var devices: [HomeDeviceHealthSnapshot]
    var totals: HomeDeviceHealthTotals
}

// MARK: - Workloads (VM dual-read)

struct Workload: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var vmType: String
    var state: String
    var health: String?
    var cpuCount: Int
    var memoryMB: Int
    var bootDiskId: String
    var isoId: String?
    var isoIds: [String]?
    var networkId: String?
    var description: String?
    var pendingChanges: Bool?
    var createdAt: String
    var updatedAt: String
    var workloadClass: String?
    var session: CodingAgentSessionInfo? = nil
    var status: WorkloadRuntimeStatus?
    var portForwards: [GuestPortForward]?
    var startOnBoot: Bool? = nil
    var gpuDevices: [GPUPassthroughDevice]?
    var usbDevices: [USBPassthroughDevice]? = nil
    var pendingImageId: String? = nil
    var downloadPercent: Int? = nil
    var macAddress: String? = nil
    var cloudInitPath: String? = nil
    var guestAddressing: GuestAddressingInfo? = nil

    var resolvedHealth: String {
        if let health, !health.isEmpty { return health }
        if let statusHealth = status?.health, !statusHealth.isEmpty { return statusHealth }
        return WorkloadHealth.derived(fromState: state)
    }

    var isRunning: Bool {
        state == "running"
    }
    var canStart: Bool {
        state == "stopped" || state == "error"
    }
    /// vfio-pci is bound at start, not hot-plugged.
    var canDetachGPU: Bool {
        canStart
    }
    var canDetachUSB: Bool {
        canStart
    }
    var canStop: Bool {
        state == "running" || state == "starting"
    }
    /// Same as the web Workload detail Restart button: running only.
    var canRestart: Bool {
        state == "running"
    }

    /// `isoIds` when present, otherwise the legacy single `isoId`.
    var attachedISOIds: [String] {
        if let isoIds, !isoIds.isEmpty { return isoIds }
        if let isoId, !isoId.isEmpty { return [isoId] }
        return []
    }

    var guestOSFamily: String {
        vmType.localizedCaseInsensitiveContains("windows") ? "Windows" : "Linux"
    }

    var isAgentClass: Bool {
        workloadClass == "agent"
    }

    var grantCopy: String {
        isAgentClass ? "WAN yes, house no." : "House: LAN and USB allowed."
    }

    /// Missing JSON is off so House appliances are not surprised.
    var startsOnDeviceBoot: Bool {
        startOnBoot == true || status?.startOnBoot == true
    }

    var startOnBootFooter: String {
        WorkloadStartOnBoot.footer(isAgent: isAgentClass)
    }
}

enum WorkloadStartOnBoot {
    static let label = "Start when this Device boots"

    static func footer(isAgent: Bool) -> String {
        if isAgent {
            return "Starts after a Device reboot. The Agent cage stays on. A BarkVisor restart does not start it."
        }
        return "Off unless you turn it on. House appliances stay stopped after a Device reboot until you start them."
    }
}

struct GuestPortForward: Decodable, Hashable {
    var proto: String
    var hostPort: Int
    var guestPort: Int

    enum CodingKeys: String, CodingKey {
        case proto = "protocol"
        case hostPort, guestPort
    }
}

struct GuestListeningPortAccess: Hashable {
    var isMember: Bool
    var guestIpsReachable: Bool
    var portForwards: [GuestPortForward]

    static let unknown = GuestListeningPortAccess(
        isMember: false,
        guestIpsReachable: false,
        portForwards: [],
    )
}

struct GuestListeningPort: Decodable, Hashable {
    var proto: String
    var address: String
    var port: Int
    var scope: String
    var label: String?
    var scheme: String?
    /// True when the JSON included `scheme` (including explicit null after a negative probe).
    var schemeKeyPresent: Bool

    init(
        proto: String,
        address: String,
        port: Int,
        scope: String,
        label: String?,
        scheme: String?,
        schemeKeyPresent: Bool = false,
    ) {
        self.proto = proto
        self.address = address
        self.port = port
        self.scope = scope
        self.label = label
        self.scheme = scheme
        self.schemeKeyPresent = schemeKeyPresent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proto = try container.decode(String.self, forKey: .proto)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        scope = try container.decode(String.self, forKey: .scope)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        schemeKeyPresent = container.contains(.scheme)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
    }

    private enum CodingKeys: String, CodingKey {
        case proto, address, port, scope, label, scheme
    }

    var isInternal: Bool {
        scope == "internal" || address.hasPrefix("127.") || address == "::1" || address == "localhost"
    }

    var isPublished: Bool {
        Self.publishedPorts.contains(port)
    }

    var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return "TCP \(port)"
    }

    var isHttpLike: Bool {
        if scheme == "http" || scheme == "https" { return true }
        if schemeKeyPresent { return false }
        return label == "HTTP" || label == "HTTPS" || label == "Dev"
    }

    func openURL(guestIPs: [String], access: GuestListeningPortAccess = .unknown) -> URL? {
        guard !isInternal, isHttpLike else { return nil }
        if access.guestIpsReachable, let host = operatorReachableHost(guestIPs: guestIPs) {
            return makeURL(host: host, listenPort: port)
        }
        if access.isMember { return nil }
        guard let hostPort = access.portForwards.first(where: {
            $0.proto == "tcp" && $0.guestPort == port
        })?.hostPort else { return nil }
        return makeURL(host: "127.0.0.1", listenPort: hostPort)
    }

    private func operatorReachableHost(guestIPs: [String]) -> String? {
        let candidate: String
        if !isWildcardAddress(address), !isInternal, address != "10.0.2.15" {
            candidate = address
        } else if let ip = guestIPs.first(where: Self.isOperatorReachableGuestAddress) {
            candidate = ip
        } else {
            return nil
        }
        return Self.isOperatorReachableGuestAddress(candidate) ? candidate : nil
    }

    private func makeURL(host: String, listenPort: Int) -> URL? {
        let proto = scheme == "https" || label == "HTTPS" ? "https" : "http"
        let wrapped = host.contains(":") ? "[\(host)]" : host
        let suffix = (listenPort == 80 && proto == "http") || (listenPort == 443 && proto == "https")
            ? "" : ":\(listenPort)"
        return URL(string: "\(proto)://\(wrapped)\(suffix)")
    }

    private func isWildcardAddress(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "*" || host.isEmpty
    }

    static func isOperatorReachableGuestAddress(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host.hasPrefix("127.") || host == "::1" || host == "localhost" { return false }
        if host == "0.0.0.0" || host == "::" || host == "*" { return false }
        if host == "10.0.2.15" { return false }
        if host.lowercased().hasPrefix("fe80:") { return false }
        return true
    }

    static let publishedPorts: Set<Int> = [
        22, 80, 81, 443,
        1_234, 1_880, 1_883, 2_283, 3_000, 3_001, 3_306, 3_389,
        4_173, 4_200, 5_000, 5_055, 5_173, 5_174, 5_432, 5_900, 6_379,
        6_767, 7_860, 7_878, 8_000, 8_080, 8_081, 8_096, 8_123, 8_188,
        8_384, 8_443, 8_686, 8_888, 8_883, 8_989, 9_000, 9_090, 9_091, 9_443, 9_696,
        11_434, 18_789, 27_017, 32_400,
    ]
}

struct GuestAddressingInfo: Decodable, Hashable {
    var mode: String
    var ipv4: String?
    var prefixLength: Int?
    var gateway: String?
    var nameservers: [String]?

    var isStatic: Bool {
        mode == "static"
    }

    var summary: String {
        if isStatic, let ipv4 {
            if let prefixLength { return "Static \(ipv4)/\(prefixLength)" }
            return "Static \(ipv4)"
        }
        return "DHCP (LAN)"
    }
}

struct GuestInfo: Decodable, Hashable {
    var available: Bool
    var ipAddresses: [String]
    var osName: String?
    var osVersion: String?
    var hostname: String?
    var listeningPorts: [GuestListeningPort]?
    var portsCollectedAt: String?
    var macAddress: String?

    init(
        available: Bool,
        ipAddresses: [String],
        osName: String? = nil,
        osVersion: String? = nil,
        hostname: String? = nil,
        listeningPorts: [GuestListeningPort]? = nil,
        portsCollectedAt: String? = nil,
        macAddress: String? = nil,
    ) {
        self.available = available
        self.ipAddresses = ipAddresses
        self.osName = osName
        self.osVersion = osVersion
        self.hostname = hostname
        self.listeningPorts = listeningPorts
        self.portsCollectedAt = portsCollectedAt
        self.macAddress = macAddress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Bool.self, forKey: .available)
        ipAddresses = try container.decodeIfPresent([String].self, forKey: .ipAddresses) ?? []
        osName = try container.decodeIfPresent(String.self, forKey: .osName)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        listeningPorts = try container.decodeIfPresent([GuestListeningPort].self, forKey: .listeningPorts)
        portsCollectedAt = try container.decodeIfPresent(String.self, forKey: .portsCollectedAt)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
    }

    var osLabel: String? {
        guard let osName, !osName.isEmpty else { return nil }
        if let osVersion, !osVersion.isEmpty { return "\(osName) \(osVersion)" }
        return osName
    }

    var primaryIP: String? {
        ipAddresses.first { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case available, ipAddresses, osName, osVersion, hostname
        case listeningPorts, portsCollectedAt, macAddress
    }
}

struct WorkloadRuntimeStatus: Decodable, Hashable {
    var state: String?
    var health: String?
    var healthError: String?
    var startOnBoot: Bool?
}

enum WorkloadHealth {
    static let stripKeys = ["running", "starting", "degraded", "failed", "stopped"]

    static func label(_ raw: String) -> String {
        switch raw {
        case "guest_ready": "Guest ready"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func derived(fromState state: String) -> String {
        switch state {
        case "error": "failed"
        case "starting", "provisioning": "starting"
        case "running", "stopping": "running"
        case "stopped", "deleting": "stopped"
        default: "unknown"
        }
    }
}

// MARK: - System / library / pairing

struct SystemStats: Decodable {
    var hostCpuPercent: Double
    var hostMemoryTotalMB: Int
    var hostMemoryUsedMB: Int
    var runningVMs: Int
    var totalVMs: Int
    var vmCpuPercent: Double
    var vmMemoryMB: Int
}

struct SystemStatsSample: Decodable, Hashable, Identifiable {
    var timestamp: String
    var hostCpuPercent: Double
    var hostMemoryUsedMB: Int
    var hostMemoryTotalMB: Int
    var hostGpuPercent: Double?

    var id: String {
        timestamp
    }

    init(
        timestamp: String,
        hostCpuPercent: Double,
        hostMemoryUsedMB: Int,
        hostMemoryTotalMB: Int,
        hostGpuPercent: Double? = nil,
    ) {
        self.timestamp = timestamp
        self.hostCpuPercent = hostCpuPercent
        self.hostMemoryUsedMB = hostMemoryUsedMB
        self.hostMemoryTotalMB = hostMemoryTotalMB
        self.hostGpuPercent = hostGpuPercent
    }
}

struct DeviceStatsChartPoint: Identifiable, Equatable {
    var id: String
    var date: Date
    var cpuPercent: Double
    var memoryUsedGB: Double
    var memoryTotalGB: Double
    var gpuPercent: Double?

    init(
        id: String,
        date: Date,
        cpuPercent: Double,
        memoryUsedGB: Double,
        memoryTotalGB: Double,
        gpuPercent: Double? = nil,
    ) {
        self.id = id
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
        self.gpuPercent = gpuPercent
    }
}

enum DeviceRename {
    static let maxLength = 64

    /// Self always; members only when the hop can reach them.
    static func canRename(_ device: HomeDeviceHealthSnapshot) -> Bool {
        device.isSelf || device.isReachable
    }

    static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }
}

enum DeviceStatsHistory {
    static let minutes = 30
    static let maxPoints = 60

    static var unreachableCopy: String {
        "This \(Copy.device.lowercased()) did not answer. Workload counts are not shown. This \(Copy.device.lowercased()) is still running locally."
    }

    static func unavailableCopy(_ device: HomeDeviceHealthSnapshot) -> String {
        if device.reachability == "unreachable" {
            return unreachableCopy
        }
        let error = device.reachabilityError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if error.isEmpty {
            return "\(DeviceReachability.label(device.reachability)). Workload counts are not shown."
        }
        return "\(error) Workload counts are not shown."
    }

    static func shouldFetch(_ device: HomeDeviceHealthSnapshot) -> Bool {
        device.isSelf || device.isReachable
    }

    static func points(from samples: [SystemStatsSample], max: Int = maxPoints) -> [DeviceStatsChartPoint] {
        guard !samples.isEmpty else { return [] }
        return Array(samples.suffix(max)).enumerated().compactMap { index, sample in
            guard let date = parseTimestamp(sample.timestamp) else { return nil }
            return DeviceStatsChartPoint(
                id: "\(sample.timestamp)-\(index)",
                date: date,
                cpuPercent: sample.hostCpuPercent,
                memoryUsedGB: Double(sample.hostMemoryUsedMB) / 1_024,
                memoryTotalGB: Double(sample.hostMemoryTotalMB) / 1_024,
                gpuPercent: sample.hostGpuPercent,
            )
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalISO.date(from: raw) ?? iso.date(from: raw)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct DeviceNameSnapshot: Decodable, Equatable {
    var displayName: String
    var hostname: String
}

struct DeviceNameUpdate: Encodable, Equatable {
    var displayName: String
}

struct SystemAbout: Decodable {
    var version: String
    var platform: String
    var hostArch: String
    var accelerator: String
    var processUptimeSeconds: Int
    var displayName: String?
}

struct CapabilityDetail: Decodable, Equatable {
    var code: String
    var supported: Bool
    var reasonCode: String?
    var remediation: String?
}

struct SystemCapabilities: Decodable, Equatable {
    var platform: String
    var supportsManagedBridgeDaemon: Bool?
    var supportsHostBridgeManagement: Bool?
    var supportsHostMutation: Bool?
    var supportsUSBPassthrough: Bool?
    var supportsGPUPassthrough: Bool?
    var supportsVFIO: Bool?
    var supportsInAppUpdate: Bool?
    var details: [CapabilityDetail]?

    func detail(code: String) -> CapabilityDetail? {
        details?.first { $0.code == code }
    }

    var usbPassthroughSupported: Bool {
        if supportsUSBPassthrough == true { return true }
        return detail(code: "usbPassthrough")?.supported == true
    }

    var linuxHostBridgeApplySupported: Bool {
        if platform.caseInsensitiveCompare("macOS") == .orderedSame { return false }
        if platform.caseInsensitiveCompare("darwin") == .orderedSame { return false }
        if supportsHostBridgeManagement == true { return true }
        if supportsHostMutation == true { return true }
        return platform.caseInsensitiveCompare("Linux") == .orderedSame
    }

    var macosSocketVmnetSupported: Bool {
        if platform.caseInsensitiveCompare("Linux") == .orderedSame { return false }
        if supportsManagedBridgeDaemon == true { return true }
        return platform.caseInsensitiveCompare("macOS") == .orderedSame
            || platform.caseInsensitiveCompare("darwin") == .orderedSame
    }

    var gpuPassthroughSupported: Bool {
        if supportsGPUPassthrough == true { return true }
        return detail(code: "gpuPassthrough")?.supported == true
    }

    var inAppUpdateSupported: Bool {
        if supportsInAppUpdate == true { return true }
        return detail(code: "inAppUpdate")?.supported == true
    }

    var inAppUpdateExplanation: String {
        let trimmed = detail(code: "inAppUpdate")?.remediation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return "In-app updates run on a root Ubuntu/Debian .deb or Apple Silicon .pkg Device."
    }

    var gpuPassthroughExplanation: String {
        GPUPassthroughCopy.explanation(
            supported: gpuPassthroughSupported,
            remediation: detail(code: "gpuPassthrough")?.remediation,
            platform: platform,
        )
    }

    var inAppUpdateSupported: Bool {
        detail(code: "inAppUpdate")?.supported == true
    }

    var inAppUpdateExplanation: String {
        let trimmed = detail(code: "inAppUpdate")?.remediation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return "In-app updates run on a root Ubuntu/Debian .deb or Apple Silicon .pkg Device."
    }
}

/// Read-only doctor list on Device detail (#403). Rows are the capabilities
/// `details[]` from `GET /api/system/capabilities` (self) or the Home proxy
/// (member); the phone shows the server remediation copy and never applies it.
enum DeviceDoctor {
    static let loadFailedCopy =
        "Could not load capability details for this \(Copy.device.lowercased())."
    static let emptyCopy =
        "This \(Copy.device.lowercased()) did not report capability details."

    static func rows(from caps: SystemCapabilities?) -> [CapabilityDetail] {
        caps?.details ?? []
    }

    static func title(for code: String) -> String {
        switch code {
        case "bridgedNetworking": "Bridged networking"
        case "managedBridgeDaemon": "Managed bridge daemon"
        case "hostBridgeManagement": "Host bridge management"
        case "usbPassthrough": "USB passthrough"
        case "inAppUpdate": "In-app update"
        case "kvmDevice": "KVM device"
        case "qemuBridgeHelper": "QEMU bridge helper"
        case "tcgOnly": "TCG software emulation"
        case "vfio": "VFIO"
        case "gpuPassthrough": "GPU passthrough"
        default: code
        }
    }

    static func statusLabel(supported: Bool) -> String {
        supported ? "Supported" : "Not supported"
    }

    /// Server remediation copy. `tcgOnly` is supported yet degraded, so the note
    /// shows whenever the server sends one, not only for unsupported rows.
    static func note(for detail: CapabilityDetail) -> String? {
        let trimmed = detail.remediation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum GPUPassthroughCopy {
    static let guestOllamaPath = "http://127.0.0.1:11434/v1"
    static let attachReady =
        "This machine has IOMMU, vfio-pci, and KVM. Attach a GPU like USB. Guest Ollama is \(guestOllamaPath). The same card cannot be host and guest."
    static let iommuNotReady =
        "GPU passthrough needs IOMMU, vfio-pci, KVM, and a GPU in an IOMMU group. This machine is not ready."
    static let singleDisplayWarning =
        "This machine lists one GPU. Passing it through can blank the host display."

    static func groupMatesLabel(pciAddress: String, groupAddresses: [String]?) -> String {
        let mates = (groupAddresses ?? []).filter { !$0.isEmpty && $0 != pciAddress }
        return mates.isEmpty ? "none" : mates.joined(separator: ", ")
    }

    static func explanation(supported: Bool, remediation: String?, platform: String) -> String {
        if supported {
            return attachReady
        }
        let trimmed = remediation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if platform.caseInsensitiveCompare("macOS") == .orderedSame {
            return "GPU passthrough is not available on macOS. Use a Linux Device with IOMMU, vfio-pci, and KVM."
        }
        return iommuNotReady
    }
}

enum USBPassthroughCopy {
    static let noSerial = "No serial, cannot persist."
}

struct USBPassthroughDevice: Decodable, Hashable, Identifiable {
    var vendorId: String
    var productId: String
    var label: String?
    var serialNumber: String?
    var deviceId: String?

    var id: String {
        deviceId ?? "\(vendorId):\(productId)"
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return id
    }
}

struct HostUSBDevice: Decodable, Hashable, Identifiable {
    var id: String
    var vendorId: String
    var productId: String
    var name: String
    var manufacturer: String?
    var serialNumber: String?
    var bus: Int?
    var address: Int?
    var idUnstable: Bool?
    var attachable: Bool?
    var excludedReason: String?
    var claimedByVMId: String?
    var claimedByVMName: String?

    var canAttach: Bool {
        attachable != false
            && claimedByVMId == nil
            && serialNumber?.isEmpty == false
    }

    var occupancyCopy: String? {
        if let claimedByVMName, !claimedByVMName.isEmpty {
            return "Attached to \(claimedByVMName)"
        }
        if attachable == false {
            return excludedReason
        }
        if idUnstable == true || serialNumber == nil || serialNumber?.isEmpty == true {
            return USBPassthroughCopy.noSerial
        }
        return nil
    }
}

struct GPUPassthroughDevice: Decodable, Hashable, Identifiable {
    var pciAddress: String
    var iommuGroup: String
    var vendorId: String
    var deviceId: String
    var pciClass: String?
    var label: String?
    var groupAddresses: [String]?

    var id: String {
        pciAddress
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return pciAddress
    }
}

struct HostGPUDevice: Decodable, Hashable, Identifiable {
    var id: String
    var pciAddress: String
    var iommuGroup: String
    var vendorId: String
    var deviceId: String
    var pciClass: String?
    var name: String
    var driver: String?
    var vfioBound: Bool?
    var inUseByHost: Bool?
    var attachable: Bool?
    var excludedReason: String?
    var groupAddresses: [String]?
    var guestOllamaPath: String?
    var busy: Bool?
    var attachedToVmId: String?
    var claimedByVMId: String?
    var claimedByVMName: String?

    var canAttach: Bool {
        attachable == true && claimedByVMId == nil
    }

    var occupancyCopy: String? {
        if let claimedByVMName, !claimedByVMName.isEmpty {
            return "Attached to \(claimedByVMName)"
        }
        if inUseByHost == true {
            return "In use by host"
        }
        return excludedReason
    }
}

struct GPUAttachBody: Encodable {
    var deviceId: String
}

struct LibraryImage: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var imageType: String
    var arch: String
    var status: String
    var sizeBytes: Int64?
    var sourceUrl: String?
    var error: String?
    var createdAt: String
    var updatedAt: String
    var downloadPercent: Int? = nil

    var isReadyISO: Bool {
        imageType == "iso" && status == "ready"
    }

    var isTransferring: Bool {
        status == "downloading" || status == "decompressing" || status == "uploading"
    }

    /// 0...1 while transferring with a known total. Nil → indeterminate ProgressView.
    var transferProgress: Double? {
        guard isTransferring, let downloadPercent else { return nil }
        return min(1, max(0, Double(downloadPercent) / 100))
    }
}

struct WorkloadISOMediaItem: Identifiable, Hashable {
    var id: String
    var name: String?
    var isMissing: Bool

    var displayName: String {
        if let name, !name.isEmpty { return name }
        let prefix = id.prefix(8)
        return isMissing ? "Missing image (\(prefix)…)" : "\(prefix)…"
    }
}

enum WorkloadISOMedia {
    /// `libraryKnown` is false until GET /images succeeds; then missing IDs are real.
    static func attached(
        ids: [String],
        library: [LibraryImage],
        libraryKnown: Bool,
    ) -> [WorkloadISOMediaItem] {
        ids.map { id in
            if let image = library.first(where: { $0.id == id }) {
                return WorkloadISOMediaItem(id: id, name: image.name, isMissing: false)
            }
            return WorkloadISOMediaItem(id: id, name: nil, isMissing: libraryKnown)
        }
    }

    static func attachable(library: [LibraryImage], attachedIDs: [String]) -> [LibraryImage] {
        library.filter { $0.isReadyISO && !attachedIDs.contains($0.id) }
    }

    static func libraryTaskID(deviceID: String, reachable: Bool) -> String {
        "\(deviceID)/\(reachable ? "up" : "down")"
    }
}

enum WorkloadISOLibraryLoad: Equatable {
    case pending
    case loaded([LibraryImage])
    case failed

    var isKnown: Bool {
        if case .loaded = self { return true }
        return false
    }

    var images: [LibraryImage] {
        if case let .loaded(images) = self { return images }
        return []
    }

    var showsSpinner: Bool {
        if case .pending = self { return true }
        return false
    }

    /// Nil from GET /images is a finished failure unless a prior load succeeded.
    func applying(_ images: [LibraryImage]?) -> Self {
        if let images { return .loaded(images) }
        if isKnown { return self }
        return .failed
    }
}

enum WorkloadISOAccess: Equatable {
    case available
    case deviceUnreachable
    case busy

    static func resolve(reachable: Bool, busy: Bool) -> WorkloadISOAccess {
        if !reachable { return .deviceUnreachable }
        if busy { return .busy }
        return .available
    }

    var allowsChange: Bool {
        self == .available
    }

    var reason: String? {
        switch self {
        case .available: nil
        case .deviceUnreachable: "That Device is unreachable."
        case .busy: "This Workload is busy."
        }
    }
}

struct ImageRepository: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var isBuiltIn: Bool
    var repoType: String
    var lastSyncedAt: String?
    var lastError: String?
    var syncStatus: String
    var createdAt: String
    var updatedAt: String
}

struct CatalogImage: Decodable, Identifiable, Hashable {
    var id: String
    var repositoryId: String
    var slug: String
    var name: String
    var description: String?
    var imageType: String
    var arch: String
    var version: String?
    var downloadUrl: String
    var sizeBytes: Int64?

    var detailLine: String {
        var parts = [imageType, arch]
        if let version, !version.isEmpty { parts.append(version) }
        if let size = LibraryCatalog.sizeLabel(sizeBytes) { parts.append(size) }
        return parts.joined(separator: " · ")
    }
}

struct DiskRecord: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var sizeBytes: Int64
    var format: String
    var vmId: String?
    var status: String
    var createdAt: String
}

struct NetworkRecord: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var mode: String
    var bridge: String?
    var isDefault: Bool
}

struct HostBridgeApplyBody: Encodable {
    var interface: String?
    var action: String
    var addressing: String
    var confirm: Bool
}

struct HostBridgeApplyResponse: Decodable, Equatable {
    var success: Bool
    var message: String?
    var applied: Bool?
    var needsConfirm: Bool?
    var backend: String?
    var changes: [String]?
    var warnings: [String]?
    var commands: [String]?
}

struct ServerLogEntry: Decodable, Hashable {
    var ts: String
    var level: String
    var cat: String
    var msg: String
    var vm: String?
    var err: String?
}

struct PairingIssue: Decodable, Hashable {
    var code: String
    var expiresAt: String
    var ttlSeconds: Int
    var qrPayload: String
    var hostId: String
    var fingerprint: String
    var caFingerprint: String
    var port: Int
    var agentPort: Int
    var advertisedHost: String?
    var advertisedHosts: [String]
    var apiVersion: Int
}

struct RemoteAccessTailnet: Decodable, Hashable {
    var available: Bool
    var ip: String?
    var dnsName: String?
}

struct RemoteAccessWireGuard: Decodable, Hashable {
    var configured: Bool
}

struct DiskSettingsSnapshot: Decodable, Equatable {
    var diskDirectory: String
    var isDefault: Bool
}

struct DiskSettingsUpdate: Encodable {
    var diskDirectory: String
}

struct UpdateInfo: Decodable, Equatable {
    var version: String
    var packageURL: String
    var checksumURL: String
    var packageKind: String
    var changelog: String
    var publishedAt: String
    var isPrerelease: Bool
}

struct UpdateCheckResponse: Decodable, Equatable {
    var currentVersion: String
    var update: UpdateInfo?
}

struct UpdateInstallRequest: Encodable {
    var version: String
}

struct UpdateTaskAccepted: Decodable, Equatable {
    var taskID: String
}

struct ProcessHealthSnapshot: Decodable, Equatable {
    var status: String
}

struct BackgroundTaskSnapshot: Decodable, Equatable {
    var taskID: String
    var status: String
    var progress: Double?
    var error: String?
}

enum ApplianceUpdateApply {
    static let consecutiveTaskMissesBeforeHealthPoll = 3

    static func isConnectionLoss(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .transport, .invalidURL:
            return true
        case let .http(status, _) where status >= 500:
            return true
        default:
            return false
        }
    }
}

struct RemoteAccessStatus: Decodable, Hashable {
    var tailscale: RemoteAccessTailnet
    var wireguard: RemoteAccessWireGuard
    var deviceUrl: String?
    var advertisedHosts: [String]

    private enum CodingKeys: String, CodingKey {
        case tailscale, wireguard, deviceUrl, advertisedHosts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tailscale = try container.decode(RemoteAccessTailnet.self, forKey: .tailscale)
        wireguard = try container.decode(RemoteAccessWireGuard.self, forKey: .wireguard)
        deviceUrl = try container.decodeIfPresent(String.self, forKey: .deviceUrl)
        advertisedHosts = try container.decodeIfPresent([String].self, forKey: .advertisedHosts) ?? []
    }
}

struct RemoteAccessUpdate: Encodable, Equatable {
    var deviceUrl: String
}

enum PairingExpiry {
    /// Remaining TTL from the offer's absolute `expiresAt`, not the issued `ttlSeconds` snapshot.
    static func remainingSeconds(expiresAt: String, now: Date = Date()) -> Int {
        guard let expiry = parseISO8601(expiresAt) else { return 0 }
        return max(0, Int(expiry.timeIntervalSince(now)))
    }

    static func label(expiresAt: String, now: Date = Date()) -> String {
        let seconds = remainingSeconds(expiresAt: expiresAt, now: now)
        if seconds == 0 { return "Expired" }
        let minutes = Int(ceil(Double(seconds) / 60))
        return minutes == 1 ? "Expires in 1 minute" : "Expires in \(minutes) minutes"
    }

    static func isActive(expiresAt: String, now: Date = Date()) -> Bool {
        remainingSeconds(expiresAt: expiresAt, now: now) > 0
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}

/// Web UI links for a Workload. Member detail/VNC is not `/vms/:id` until PAS-202/200 land.
enum WorkloadWebLink {
    static func page(base: URL, workloadID: String, device: HomeDeviceHealthSnapshot?) -> URL {
        if let device, !device.isSelf {
            return base.appending(path: "devices").appending(path: device.hostId)
        }
        return base.appending(path: "vms").appending(path: workloadID)
    }

    static func console(base: URL, workloadID: String, device: HomeDeviceHealthSnapshot?) -> URL {
        let page = page(base: base, workloadID: workloadID, device: device)
        if let device, !device.isSelf { return page }
        return page.appending(path: "vnc")
    }
}

struct WorkloadStopBody: Encodable {
    var force: Bool
    var method: String
}

struct WorkloadStartOnBootBody: Encodable, Equatable {
    var startOnBoot: Bool
}

struct ISOMediaBody: Encodable {
    var isoId: String
}

struct EmptyJSON: Encodable {}

// MARK: - Home tab union (reachable Devices only)

enum WorkloadActionKey {
    static func id(hostID: String?, workloadID: String) -> String {
        guard let hostID, !hostID.isEmpty else { return workloadID }
        return "\(hostID)/\(workloadID)"
    }
}

/// Web Restart is shown for `state === 'running'` and disabled while a control
/// is in flight or the member Device did not answer.
enum WorkloadRestart {
    static func isEnabled(device: HomeDeviceHealthSnapshot, busy: Bool) -> Bool {
        !busy && (device.isSelf || device.isReachable)
    }
}

struct HomeWorkloadRow: Identifiable, Hashable {
    var workload: Workload
    var device: HomeDeviceHealthSnapshot

    var id: String {
        WorkloadActionKey.id(hostID: device.hostId, workloadID: workload.id)
    }
}

struct HomeDeviceLoadError: Identifiable, Hashable {
    var device: HomeDeviceHealthSnapshot
    var message: String

    var id: String {
        device.hostId
    }
}

/// Cross-Device Workload list. Unreachable Devices never contribute invented rows.
enum HomeWorkloadUnion {
    enum Load: Equatable {
        case success([Workload])
        case failure(String)
    }

    struct Snapshot: Equatable {
        var rows: [HomeWorkloadRow]
        var loadErrors: [HomeDeviceLoadError]
        var unreachable: [HomeDeviceHealthSnapshot]
    }

    static func build(
        devices: [HomeDeviceHealthSnapshot],
        loads: [String: Load],
    ) -> Snapshot {
        var rows: [HomeWorkloadRow] = []
        var loadErrors: [HomeDeviceLoadError] = []
        var unreachable: [HomeDeviceHealthSnapshot] = []
        for device in devices {
            if !device.isReachable {
                unreachable.append(device)
                continue
            }
            guard let load = loads[device.hostId] else { continue }
            switch load {
            case let .success(workloads):
                rows.append(contentsOf: workloads.map { HomeWorkloadRow(workload: $0, device: device) })
            case let .failure(message):
                loadErrors.append(HomeDeviceLoadError(device: device, message: message))
            }
        }
        rows.sort { lhs, rhs in
            if lhs.device.title != rhs.device.title { return lhs.device.title < rhs.device.title }
            if lhs.workload.name != rhs.workload.name { return lhs.workload.name < rhs.workload.name }
            return lhs.id < rhs.id
        }
        return Snapshot(rows: rows, loadErrors: loadErrors, unreachable: unreachable)
    }
}
