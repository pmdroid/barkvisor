import BarkVisorCore

/// Home-owned reachability state for paired Devices.
///
/// The browser renders this state but never decides whether a member hop is
/// allowed. Unknown members remain callable until the first probe completes.
actor HomeDeviceReachabilityMonitor {
    static let refreshIntervalNanoseconds: UInt64 = 5_000_000_000

    private struct CachedReport {
        var report: HomeDeviceHealthReport
        var at: ContinuousClock.Instant
    }

    private var statusByHostId: [String: String] = [:]
    private var cached: CachedReport?
    private var inflight: Task<HomeDeviceHealthReport, Never>?
    private var inflightToken = 0

    func freshReport(now: ContinuousClock.Instant = .now) -> HomeDeviceHealthReport? {
        guard let cached else { return nil }
        let age = cached.at.duration(to: now)
        guard age < .nanoseconds(Int64(Self.refreshIntervalNanoseconds)) else { return nil }
        return cached.report
    }

    func joinProbe(
        _ make: @Sendable @escaping () async -> HomeDeviceHealthReport,
    ) async -> HomeDeviceHealthReport {
        if let inflight {
            return await inflight.value
        }
        inflightToken += 1
        let token = inflightToken
        let task = Task.detached(operation: make)
        inflight = task
        let report = await task.value
        if inflightToken == token {
            inflight = nil
        }
        cached = CachedReport(report: report, at: .now)
        return report
    }

    func replace(_ devices: [HomeDeviceHealthSnapshot]) {
        statusByHostId = Dictionary(
            uniqueKeysWithValues: devices.compactMap { device in
                device.role == "self" ? nil : (device.hostId, device.reachability)
            },
        )
    }

    func replace(_ statuses: [String: String]) {
        statusByHostId = statuses
    }

    func markUnavailable(_ hostId: String) {
        guard statusByHostId[hostId] != nil else { return }
        statusByHostId[hostId] = HomeDeviceHealthAggregator.unreachable
    }

    func remove(_ hostId: String) {
        statusByHostId.removeValue(forKey: hostId)
    }

    func permitsHop(to hostId: String) -> Bool {
        guard let status = statusByHostId[hostId] else { return true }
        // An application response, even a 5xx, proves the mTLS transport is
        // healthy. Only transport reachability failures suppress a proxy hop.
        return status == HomeDeviceHealthAggregator.ok
            || status == HomeDeviceHealthAggregator.memberHTTP
    }
}
