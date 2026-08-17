import Foundation

// MARK: - Product copy (docs/product-terminology.md)

enum Copy {
    static let home = "Home"
    static let device = "Device"
    static let devices = "Devices"
    static let workload = "Workload"
    static let workloads = "Workloads"
    static let library = "Library"
}

// MARK: - Auth / setup

struct LoginRequest: Encodable {
    var username: String
    var password: String
}

struct LoginResponse: Decodable {
    var token: String
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

    var id: String { hostId }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }

    var isSelf: Bool { role == "self" }

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
            healthCounts: nil
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

    var id: String { hostId }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }

    var isSelf: Bool { role == "self" }
    var isReachable: Bool { reachability == "ok" }

    /// Fallback when a Mac Workloads list has no selected Device snapshot yet.
    static var placeholderSelf: HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: "self",
            role: "self",
            displayName: "This Device",
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
            healthCounts: nil
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
    var networkId: String?
    var description: String?
    var pendingChanges: Bool?
    var createdAt: String
    var updatedAt: String
    var status: WorkloadRuntimeStatus?

    var resolvedHealth: String {
        if let health, !health.isEmpty { return health }
        if let statusHealth = status?.health, !statusHealth.isEmpty { return statusHealth }
        return WorkloadHealth.derived(fromState: state)
    }

    var isRunning: Bool { state == "running" }
    var canStart: Bool { state == "stopped" || state == "error" }
    var canStop: Bool { state == "running" || state == "starting" }
}

struct WorkloadRuntimeStatus: Decodable, Hashable {
    var state: String?
    var health: String?
    var healthError: String?
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

struct SystemAbout: Decodable {
    var version: String
    var platform: String
    var hostArch: String
    var accelerator: String
    var processUptimeSeconds: Int
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
    var advertisedHosts: [String]
    var apiVersion: Int
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

struct EmptyJSON: Encodable {}

// MARK: - Home tab union (reachable Devices only)

struct HomeWorkloadRow: Identifiable, Hashable {
    var workload: Workload
    var device: HomeDeviceHealthSnapshot

    var id: String { "\(device.hostId)/\(workload.id)" }
}

struct HomeDeviceLoadError: Identifiable, Hashable {
    var device: HomeDeviceHealthSnapshot
    var message: String

    var id: String { device.hostId }
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
        loads: [String: Load]
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
