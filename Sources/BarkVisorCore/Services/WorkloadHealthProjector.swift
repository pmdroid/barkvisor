import Foundation

/// Derives `WorkloadHealth` from VM state plus optional live signals.
///
/// Rules (Wave 0 + PAS-65):
/// - No HTTP/TCP check and no fresh guest agent → process state only (`running`).
/// - Failed QEMU (`error` state or dead process while marked running) is `failed`.
/// - Fresh guest agent (`lastSeenAt` within `guestAgentStaleAfter`) or passing
///   HTTP/TCP probes promote `running` to `guest_ready`.
/// - A configured probe that has failed is `degraded`. Missing guest agent is
///   never a failure.
public enum WorkloadHealthProjector {
    /// Guest-info older than this is not `guest_ready`. Metrics poll every 5s.
    public static let guestAgentStaleAfter: TimeInterval = 90

    public static func project(
        state: VMState,
        signals: WorkloadHealthSignals = .unobserved,
        updatedAt: String,
        now: Date = Date(),
    ) -> WorkloadHealthStatus {
        let checks = makeChecks(state: state, signals: signals, now: now)
        let (health, lastError) = rollup(state: state, signals: signals, now: now)
        return WorkloadHealthStatus(
            health: health,
            checks: checks,
            updatedAt: updatedAt,
            lastError: lastError,
        )
    }

    public static func summarize(
        items: [WorkloadHealthSummaryItem],
        updatedAt: String,
    ) -> WorkloadHealthSummary {
        var counts = Dictionary(uniqueKeysWithValues: WorkloadHealth.allCases.map { ($0.rawValue, 0) })
        for item in items {
            counts[item.health.rawValue, default: 0] += 1
        }
        return WorkloadHealthSummary(counts: counts, items: items, updatedAt: updatedAt)
    }

    /// `/api/health` rollup: database failure is `error`; any other failed check
    /// is `degraded`; otherwise `ok`.
    public static func processHealth(
        checks: [WorkloadHealthCheck],
        updatedAt: String,
    ) -> ProcessHealthStatus {
        if checks.contains(where: { $0.name == "database" && $0.status == .fail }) {
            return ProcessHealthStatus(status: "error", checks: checks, updatedAt: updatedAt)
        }
        if checks.contains(where: { $0.status == .fail }) {
            return ProcessHealthStatus(status: "degraded", checks: checks, updatedAt: updatedAt)
        }
        return ProcessHealthStatus(status: "ok", checks: checks, updatedAt: updatedAt)
    }

    // MARK: - Private

    private static func rollup(
        state: VMState,
        signals: WorkloadHealthSignals,
        now: Date,
    ) -> (WorkloadHealth, String?) {
        switch state {
        case .error:
            return (.failed, signals.lastError ?? "QEMU entered error state")
        case .stopped, .deleting:
            return (.stopped, nil)
        case .starting, .provisioning:
            return (.starting, nil)
        case .stopping:
            if signals.qemuProcess == false {
                return (.stopped, nil)
            }
            return (.running, nil)
        case .running:
            if signals.qemuProcess == false {
                return (.failed, signals.lastError ?? "QEMU process not running")
            }
            if signals.qmp == false {
                return (.degraded, signals.lastError ?? "QMP unreachable")
            }
            if signals.probesFailed {
                return (.degraded, probeFailMessage(signals))
            }
            if isGuestAgentFresh(signals, now: now) || signals.probesPassed {
                return (.guestReady, nil)
            }
            return (.running, nil)
        }
    }

    private static func makeChecks(
        state: VMState,
        signals: WorkloadHealthSignals,
        now: Date,
    ) -> [WorkloadHealthCheck] {
        let active = state == .running || state == .starting || state == .stopping
        return [
            check(
                name: "qemuProcess",
                observed: signals.qemuProcess,
                skipWhen: !active && signals.qemuProcess == nil,
                failMessage: signals.lastError ?? "QEMU process not running",
                passMessage: "QEMU process running",
            ),
            check(
                name: "qmp",
                observed: signals.qmp,
                skipWhen: !active && signals.qmp == nil,
                failMessage: "QMP socket unreachable",
                passMessage: "QMP socket present",
            ),
            guestAgentCheck(signals: signals, now: now),
            probeCheck(
                name: "http",
                configured: signals.httpConfigured,
                observed: signals.http,
                failMessage: "HTTP probe failed",
                passMessage: "HTTP probe passed",
            ),
            probeCheck(
                name: "tcp",
                configured: signals.tcpConfigured,
                observed: signals.tcp,
                failMessage: "TCP probe failed",
                passMessage: "TCP probe passed",
            ),
        ]
    }

    private static func guestAgentCheck(
        signals: WorkloadHealthSignals,
        now: Date,
    ) -> WorkloadHealthCheck {
        guard let lastSeenAt = signals.lastSeenAt, signals.guestAgent == true else {
            return WorkloadHealthCheck(
                name: "guestAgent",
                status: .skip,
                message: "guest agent not required",
            )
        }
        if isGuestAgentFresh(signals, now: now) {
            return WorkloadHealthCheck(
                name: "guestAgent",
                status: .pass,
                message: "lastSeenAt \(lastSeenAt)",
            )
        }
        return WorkloadHealthCheck(
            name: "guestAgent",
            status: .skip,
            message: "lastSeenAt stale \(lastSeenAt)",
        )
    }

    private static func probeCheck(
        name: String,
        configured: Bool,
        observed: Bool?,
        failMessage: String,
        passMessage: String,
    ) -> WorkloadHealthCheck {
        if !configured {
            return WorkloadHealthCheck(name: name, status: .skip, message: "not configured")
        }
        return check(
            name: name,
            observed: observed,
            skipWhen: observed == nil,
            failMessage: failMessage,
            passMessage: passMessage,
        )
    }

    public static func isGuestAgentFresh(
        _ signals: WorkloadHealthSignals,
        now: Date = Date(),
        staleAfter: TimeInterval = guestAgentStaleAfter,
    ) -> Bool {
        guard signals.guestAgent == true, let raw = signals.lastSeenAt else { return false }
        guard let seen = iso8601.date(from: raw) else { return false }
        return now.timeIntervalSince(seen) <= staleAfter
    }

    private static func probeFailMessage(_ signals: WorkloadHealthSignals) -> String {
        if signals.http == false, signals.tcp == false {
            return "HTTP and TCP probes failed"
        }
        if signals.http == false { return "HTTP probe failed" }
        if signals.tcp == false { return "TCP probe failed" }
        return "probe failed"
    }

    private static func check(
        name: String,
        observed: Bool?,
        skipWhen: Bool,
        failMessage: String,
        passMessage: String,
    ) -> WorkloadHealthCheck {
        if skipWhen || observed == nil {
            return WorkloadHealthCheck(name: name, status: .skip, message: "not observed")
        }
        if observed == true {
            return WorkloadHealthCheck(name: name, status: .pass, message: passMessage)
        }
        return WorkloadHealthCheck(name: name, status: .fail, message: failMessage)
    }
}
