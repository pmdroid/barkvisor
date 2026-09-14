import BarkVisorCore

/// Home-owned reachability state for paired Devices.
///
/// The browser renders this state but never decides whether a member hop is
/// allowed. Unknown members remain callable until the first probe completes.
actor HomeDeviceReachabilityMonitor {
    static let refreshIntervalNanoseconds: UInt64 = 5_000_000_000

    private var statusByHostId: [String: String] = [:]

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
