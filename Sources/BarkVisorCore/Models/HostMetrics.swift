import Foundation

/// Inventory fields needed to build `HostMetrics` without a full snapshot.
public struct HostMetricsSlice: Sendable, Equatable {
    public let hostId: String
    public let collectedAt: String
    public let resources: ResourcesInfo
    public let storage: [StorageEntry]

    public init(
        hostId: String,
        collectedAt: String,
        resources: ResourcesInfo,
        storage: [StorageEntry],
    ) {
        self.hostId = hostId
        self.collectedAt = collectedAt
        self.resources = resources
        self.storage = storage
    }
}

/// Normalized host metrics for `/api/system/stats` (PAS-85).
///
/// Wave 0 is **local** only. Heartbeat embedding and `/api/home/devices/:id/metrics`
/// are Wave 1.
///
/// Field sources (do not call `HostInventoryService.snapshot()` on the 5s poll):
/// - `hostId` / `collectedAt` / `storage` ← `HostInventoryService.metricsSlice`
/// - `cpuLoadPercent` / `memoryTotalMB` / `memoryUsedMB` ← live `PlatformHost`
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
        from(
            slice: HostMetricsSlice(
                hostId: inventory.hostId,
                collectedAt: inventory.collectedAt,
                resources: inventory.resources,
                storage: inventory.storage,
            ),
            capture: capture,
        )
    }

    /// Project from the lightweight stats slice (no interface / guest / kvm walk).
    public static func from(slice: HostMetricsSlice, capture: HostMetricsCapture) -> HostMetrics {
        HostMetrics(
            hostId: slice.hostId,
            collectedAt: slice.collectedAt,
            cpuLoadPercent: slice.resources.cpuLoadPercent,
            memoryTotalMB: slice.resources.memoryTotalMB,
            memoryUsedMB: slice.resources.memoryUsedMB,
            storage: slice.storage,
            temperatureC: capture.temperatureC,
            uptimeSeconds: capture.uptimeSeconds,
            agentHealthy: capture.agentHealthy,
        )
    }

    /// Live `/api/system/stats` projection. CPU/mem are sampled every call;
    /// hostId, dataDir storage, and temperature refresh on the poll interval.
    public static func live(
        now: Date = Date(),
        dataDir: URL = Config.dataDir,
        hostId: String? = nil,
        capture: HostMetricsCapture = .live(),
    ) -> HostMetrics {
        from(
            slice: HostInventoryService.metricsSlice(now: now, dataDir: dataDir, hostId: hostId),
            capture: capture,
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
    /// Linux thermal sysfs is cached for `HostInventoryService.metricsSliceTTL`.
    public static func live(now: Date = Date()) -> HostMetricsCapture {
        HostMetricsCapture(
            temperatureC: temperatureCache.reading(now: now, ttl: HostInventoryService.metricsSliceTTL) {
                PlatformHost.temperatureCelsius
            },
            uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime.rounded(.down)),
            agentHealthy: true,
        )
    }

    static func resetTemperatureCache() {
        temperatureCache.reset()
    }
}

private let temperatureCache = TemperatureCache()

/// Poll-interval cache for Linux `/sys/class/thermal` (nil on macOS).
private final class TemperatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (value: Double?, expiresAt: Date)?

    func reading(now: Date, ttl: TimeInterval, load: () -> Double?) -> Double? {
        lock.lock()
        if let cached, cached.expiresAt > now {
            let value = cached.value
            lock.unlock()
            return value
        }
        lock.unlock()
        let value = load()
        lock.lock()
        cached = (value, now.addingTimeInterval(ttl))
        lock.unlock()
        return value
    }

    func reset() {
        lock.lock()
        cached = nil
        lock.unlock()
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
