import Foundation

/// Normalized host metrics for `/api/system/stats` (PAS-85).
///
/// Wave 0 is **local** only. Heartbeat embedding and `/api/home/devices/:id/metrics`
/// are Wave 1.
///
/// Field parity with `HostInventory`:
/// - `hostId` / `collectedAt` ← inventory
/// - `cpuLoadPercent` / `memoryTotalMB` / `memoryUsedMB` ← `inventory.resources`
/// - `storage` ← `inventory.storage` (dataDir volume; not a full mount list)
///
/// `temperatureC` is best-effort: **null when no sensor is readable**. Never
/// substitute `0` for a missing reading — the UI must not render that as 0°C.
public struct HostMetrics: Sendable, Equatable {
    public let hostId: String
    public let collectedAt: String
    public let cpuLoadPercent: Double
    public let memoryTotalMB: Int
    public let memoryUsedMB: Int
    public let storage: [StorageEntry]
    public let temperatureC: Double?
    public let uptimeSeconds: Int
    public let agentHealthy: Bool

    public init(
        hostId: String,
        collectedAt: String,
        cpuLoadPercent: Double,
        memoryTotalMB: Int,
        memoryUsedMB: Int,
        storage: [StorageEntry],
        temperatureC: Double?,
        uptimeSeconds: Int,
        agentHealthy: Bool,
    ) {
        self.hostId = hostId
        self.collectedAt = collectedAt
        self.cpuLoadPercent = cpuLoadPercent
        self.memoryTotalMB = memoryTotalMB
        self.memoryUsedMB = memoryUsedMB
        self.storage = storage
        self.temperatureC = temperatureC
        self.uptimeSeconds = uptimeSeconds
        self.agentHealthy = agentHealthy
    }

    /// Project host metrics from an inventory snapshot plus live probes.
    public static func from(inventory: HostInventory, capture: HostMetricsCapture) -> HostMetrics {
        HostMetrics(
            hostId: inventory.hostId,
            collectedAt: inventory.collectedAt,
            cpuLoadPercent: inventory.resources.cpuLoadPercent,
            memoryTotalMB: inventory.resources.memoryTotalMB,
            memoryUsedMB: inventory.resources.memoryUsedMB,
            storage: inventory.storage,
            temperatureC: capture.temperatureC,
            uptimeSeconds: capture.uptimeSeconds,
            agentHealthy: capture.agentHealthy,
        )
    }
}

/// Live / injected probes that are not part of `HostInventory.resources`.
public struct HostMetricsCapture: Sendable, Equatable {
    public let temperatureC: Double?
    public let uptimeSeconds: Int
    public let agentHealthy: Bool

    public init(temperatureC: Double?, uptimeSeconds: Int, agentHealthy: Bool = true) {
        self.temperatureC = temperatureC
        self.uptimeSeconds = uptimeSeconds
        self.agentHealthy = agentHealthy
    }

    /// Temperature is nil when no sensor is readable. `agentHealthy` is true
    /// for this colocated process (Wave 0 has no remote agent heartbeat).
    public static func live() -> HostMetricsCapture {
        HostMetricsCapture(
            temperatureC: PlatformHost.temperatureCelsius,
            uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime.rounded(.down)),
            agentHealthy: true,
        )
    }
}

extension HostMetrics: Codable {
    enum CodingKeys: String, CodingKey {
        case hostId
        case collectedAt
        case cpuLoadPercent
        case memoryTotalMB
        case memoryUsedMB
        case storage
        case temperatureC
        case uptimeSeconds
        case agentHealthy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(collectedAt, forKey: .collectedAt)
        try container.encode(cpuLoadPercent, forKey: .cpuLoadPercent)
        try container.encode(memoryTotalMB, forKey: .memoryTotalMB)
        try container.encode(memoryUsedMB, forKey: .memoryUsedMB)
        try container.encode(storage, forKey: .storage)
        // Always emit the key so clients can distinguish "missing sensor" from
        // an omitted field. Missing → JSON null, never 0.
        if let temperatureC {
            try container.encode(temperatureC, forKey: .temperatureC)
        } else {
            try container.encodeNil(forKey: .temperatureC)
        }
        try container.encode(uptimeSeconds, forKey: .uptimeSeconds)
        try container.encode(agentHealthy, forKey: .agentHealthy)
    }
}
