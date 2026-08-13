import Foundation

/// Derives `WorkloadHealth` from VM state plus optional live signals.
///
/// Wave 0 rules (multi-reviewer synthesis, 2026-08-12):
/// - Running without guest agent is **running**, not failed / not `guest_ready`.
/// - Failed QEMU (`error` state or dead process while marked running) is `failed`
///   with a last-error string.
/// - `guest_ready` is never emitted here (PAS-65).
public enum WorkloadHealthProjector {
    public static func project(
        state: VMState,
        signals: WorkloadHealthSignals = .unobserved,
        updatedAt: String,
    ) -> WorkloadHealthStatus {
        let checks = makeChecks(state: state, signals: signals)
        let (health, lastError) = rollup(state: state, signals: signals)
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
            // guestAgent / lastSeenAt are informational only until PAS-65.
            return (.running, nil)
        }
    }

    private static func makeChecks(
        state: VMState,
        signals: WorkloadHealthSignals,
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
            guestAgentCheck(signals: signals),
        ]
    }

    private static func guestAgentCheck(signals: WorkloadHealthSignals) -> WorkloadHealthCheck {
        if signals.guestAgent == true {
            let message = signals.lastSeenAt.map { "lastSeenAt \($0)" } ?? "guest agent reporting"
            return WorkloadHealthCheck(name: "guestAgent", status: .pass, message: message)
        }
        // Missing guest agent is not a failure (Wave 0 / PAS-65).
        let message = signals.lastSeenAt.map { "lastSeenAt \($0)" }
            ?? "guest agent not required"
        return WorkloadHealthCheck(name: "guestAgent", status: .skip, message: message)
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
