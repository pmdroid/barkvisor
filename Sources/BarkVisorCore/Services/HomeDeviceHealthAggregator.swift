import Foundation

/// Home-wide device health (PAS-52).
///
/// `GET /api/home/devices` stays local-only. This layer best-effort probes
/// members; a down peer never drops this Device from the report (PAS-47 / PAS-90).
public enum HomeDeviceProbeOutcome: Sendable, Equatable {
    case ok(HomeDeviceLiveFacts)
    case unreachable(String)
}

public enum HomeDeviceHealthAggregator {
    public static let ok = "ok"
    public static let unreachable = "unreachable"

    /// Merge the local registry list with live facts. `self` is always `ok`.
    public static func report(
        listed: HomeDeviceList,
        local: HomeDeviceLiveFacts,
        members: [String: HomeDeviceProbeOutcome],
    ) -> HomeDeviceHealthReport {
        var rows: [HomeDeviceHealthSnapshot] = []
        rows.reserveCapacity(listed.devices.count)
        for device in listed.devices {
            if device.role == "self" {
                rows.append(snapshot(device: device, facts: local, error: nil))
                continue
            }
            switch members[device.hostId] {
            case let .ok(facts):
                rows.append(snapshot(device: device, facts: facts, error: nil))
            case let .unreachable(reason):
                rows.append(snapshot(device: device, facts: nil, error: reason))
            case nil:
                rows.append(
                    snapshot(device: device, facts: nil, error: "Device is unreachable"),
                )
            }
        }
        return HomeDeviceHealthReport(devices: rows, totals: totals(from: rows))
    }

    public static func facts(
        from inventory: HostInventory,
        summary: WorkloadHealthSummary? = nil,
    ) -> HomeDeviceLiveFacts {
        HomeDeviceLiveFacts(
            displayName: inventory.displayName,
            collectedAt: inventory.collectedAt,
            platform: HomeDevicePlatformSummary(
                os: inventory.platform.os,
                arch: inventory.platform.arch,
            ),
            resources: HomeDeviceResourceSummary(
                cpuCount: inventory.resources.cpuCount,
                memoryTotalMB: inventory.resources.memoryTotalMB,
                memoryUsedMB: inventory.resources.memoryUsedMB,
                cpuLoadPercent: inventory.resources.cpuLoadPercent,
            ),
            features: HomeDeviceFeatureSummary(from: inventory.virtualization.features),
            workloadCount: summary.map(\.items.count),
            healthCounts: summary?.counts,
            addresses: inventory.networking.addresses,
        )
    }

    public static func decodeInventory(_ data: Data) throws -> HostInventory {
        try JSONDecoder().decode(HostInventory.self, from: data)
    }

    public static func decodeHealthSummary(_ data: Data) throws -> WorkloadHealthSummary {
        try JSONDecoder().decode(WorkloadHealthSummary.self, from: data)
    }

    public static func snapshot(
        device: HomeDevice,
        facts: HomeDeviceLiveFacts?,
        error: String?,
    ) -> HomeDeviceHealthSnapshot {
        let reachable = error == nil
        return HomeDeviceHealthSnapshot(
            hostId: device.hostId,
            role: device.role,
            displayName: facts?.displayName ?? device.displayName,
            fingerprint: device.fingerprint,
            agentHost: device.agentHost,
            agentPort: device.agentPort,
            pairedAt: device.pairedAt,
            reachability: reachable ? ok : unreachable,
            reachabilityError: error,
            collectedAt: facts?.collectedAt,
            platform: facts?.platform,
            resources: reachable ? facts?.resources : nil,
            features: reachable ? facts?.features : nil,
            workloadCount: reachable ? facts?.workloadCount : nil,
            healthCounts: reachable ? facts?.healthCounts : nil,
            addresses: reachable ? facts?.addresses : nil,
        )
    }

    public static func totals(from rows: [HomeDeviceHealthSnapshot]) -> HomeDeviceHealthTotals {
        var reachable = 0
        var unreachable = 0
        var knownWorkloadCount = 0
        var workloadCountComplete = true
        var healthCounts: [String: Int] = [:]
        for row in rows {
            if row.reachability == ok {
                reachable += 1
                if let count = row.workloadCount {
                    knownWorkloadCount += count
                } else {
                    workloadCountComplete = false
                }
                if let counts = row.healthCounts {
                    for (key, value) in counts {
                        healthCounts[key, default: 0] += value
                    }
                }
            } else {
                unreachable += 1
            }
        }
        return HomeDeviceHealthTotals(
            devices: rows.count,
            reachable: reachable,
            unreachable: unreachable,
            workloadCount: workloadCountComplete ? knownWorkloadCount : nil,
            healthCounts: healthCounts,
        )
    }
}
