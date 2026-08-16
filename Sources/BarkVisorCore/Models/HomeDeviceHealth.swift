import Foundation

/// Live facts for one Device on the Home dashboard (PAS-52).
///
/// Missing resource / health fields mean the member was unreachable or the
/// probe returned no body. Listing still includes the Device.
public struct HomeDeviceLiveFacts: Sendable, Equatable {
    public var displayName: String?
    public var collectedAt: String?
    public var platform: HomeDevicePlatformSummary?
    public var resources: HomeDeviceResourceSummary?
    public var workloadCount: Int?
    public var healthCounts: [String: Int]?

    public init(
        displayName: String? = nil,
        collectedAt: String? = nil,
        platform: HomeDevicePlatformSummary? = nil,
        resources: HomeDeviceResourceSummary? = nil,
        workloadCount: Int? = nil,
        healthCounts: [String: Int]? = nil,
    ) {
        self.displayName = displayName
        self.collectedAt = collectedAt
        self.platform = platform
        self.resources = resources
        self.workloadCount = workloadCount
        self.healthCounts = healthCounts
    }
}

public struct HomeDevicePlatformSummary: Codable, Sendable, Equatable {
    public var os: String
    public var arch: String

    public init(os: String, arch: String) {
        self.os = os
        self.arch = arch
    }
}

public struct HomeDeviceResourceSummary: Codable, Sendable, Equatable {
    public var cpuCount: Int?
    public var memoryTotalMB: Int?
    public var memoryUsedMB: Int?
    public var cpuLoadPercent: Double?

    public init(
        cpuCount: Int? = nil,
        memoryTotalMB: Int? = nil,
        memoryUsedMB: Int? = nil,
        cpuLoadPercent: Double? = nil,
    ) {
        self.cpuCount = cpuCount
        self.memoryTotalMB = memoryTotalMB
        self.memoryUsedMB = memoryUsedMB
        self.cpuLoadPercent = cpuLoadPercent
    }
}

/// One row in `GET /api/home/devices/health`.
public struct HomeDeviceHealthSnapshot: Codable, Sendable, Equatable {
    public var hostId: String
    public var role: String
    public var displayName: String?
    public var fingerprint: String?
    public var agentHost: String?
    public var agentPort: Int
    public var pairedAt: String?
    public var reachability: String
    public var reachabilityError: String?
    public var collectedAt: String?
    public var platform: HomeDevicePlatformSummary?
    public var resources: HomeDeviceResourceSummary?
    public var workloadCount: Int?
    public var healthCounts: [String: Int]?

    public init(
        hostId: String,
        role: String,
        displayName: String? = nil,
        fingerprint: String? = nil,
        agentHost: String? = nil,
        agentPort: Int = Config.agentPort,
        pairedAt: String? = nil,
        reachability: String,
        reachabilityError: String? = nil,
        collectedAt: String? = nil,
        platform: HomeDevicePlatformSummary? = nil,
        resources: HomeDeviceResourceSummary? = nil,
        workloadCount: Int? = nil,
        healthCounts: [String: Int]? = nil,
    ) {
        self.hostId = hostId
        self.role = role
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.pairedAt = pairedAt
        self.reachability = reachability
        self.reachabilityError = reachabilityError
        self.collectedAt = collectedAt
        self.platform = platform
        self.resources = resources
        self.workloadCount = workloadCount
        self.healthCounts = healthCounts
    }
}

public struct HomeDeviceHealthTotals: Codable, Sendable, Equatable {
    public var devices: Int
    public var reachable: Int
    public var unreachable: Int
    /// Sum of known per-device counts. `nil` when any reachable Device
    /// did not return a workload health summary — never treat unknown as 0.
    public var workloadCount: Int?
    public var healthCounts: [String: Int]

    public init(
        devices: Int,
        reachable: Int,
        unreachable: Int,
        workloadCount: Int?,
        healthCounts: [String: Int],
    ) {
        self.devices = devices
        self.reachable = reachable
        self.unreachable = unreachable
        self.workloadCount = workloadCount
        self.healthCounts = healthCounts
    }
}

/// `GET /api/home/devices/health` body.
public struct HomeDeviceHealthReport: Codable, Sendable, Equatable {
    public var devices: [HomeDeviceHealthSnapshot]
    public var totals: HomeDeviceHealthTotals

    public init(devices: [HomeDeviceHealthSnapshot], totals: HomeDeviceHealthTotals) {
        self.devices = devices
        self.totals = totals
    }
}
