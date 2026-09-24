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

    public static let observationStaleAfter: TimeInterval = 90

    public static func project(
        state: VMState,
        signals: WorkloadHealthSignals = .unobserved,
        updatedAt: String,
        now: Date = Date(),
        kind: String = WorkloadSpec.kindVirtualMachine,
        services: [WorkloadServiceObservation] = [],
        observedAt: String? = nil,
        freshness: String = "unknown",
        appliedGeneration: Int? = nil,
    ) -> WorkloadHealthStatus {
        let application = kind == WorkloadSpec.kindApplication
        let checks = application
            ? applicationChecks(state: state, signals: signals, services: services)
            : makeChecks(state: state, signals: signals, now: now)
        let (health, lastError) = application
            ? applicationRollup(state: state, signals: signals, services: services)
            : rollup(state: state, signals: signals, now: now)
        let facts = distinguish(
            kind: kind,
            state: state,
            signals: signals,
            services: services,
            health: health,
            now: now,
        )
        return WorkloadHealthStatus(
            health: health,
            checks: checks,
            updatedAt: updatedAt,
            lastError: lastError,
            running: facts.running,
            readiness: facts.readiness,
            condition: facts.condition,
            observation: resolvedFreshness(stored: freshness, observedAt: observedAt, now: now),
            appliedGeneration: appliedGeneration,
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
                unreachable: signals.httpUnreachable,
                failMessage: "HTTP probe failed",
                passMessage: "HTTP probe passed",
            ),
            probeCheck(
                name: "tcp",
                configured: signals.tcpConfigured,
                observed: signals.tcp,
                unreachable: signals.tcpUnreachable,
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
        unreachable: Bool,
        failMessage: String,
        passMessage: String,
    ) -> WorkloadHealthCheck {
        if !configured {
            return WorkloadHealthCheck(name: name, status: .skip, message: "not configured")
        }
        if unreachable {
            return WorkloadHealthCheck(name: name, status: .skip, message: "unreachable target")
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

    private static func applicationChecks(
        state: VMState,
        signals: WorkloadHealthSignals,
        services: [WorkloadServiceObservation],
    ) -> [WorkloadHealthCheck] {
        var checks = services.map { serviceCheck($0) }
        if services.isEmpty {
            checks.append(
                WorkloadHealthCheck(
                    name: "services",
                    status: .skip,
                    message: "no service observations",
                ),
            )
        }
        checks.append(
            probeCheck(
                name: "http",
                configured: signals.httpConfigured,
                observed: signals.http,
                unreachable: signals.httpUnreachable,
                failMessage: "HTTP probe failed",
                passMessage: "HTTP probe passed",
            ),
        )
        checks.append(
            probeCheck(
                name: "tcp",
                configured: signals.tcpConfigured,
                observed: signals.tcp,
                unreachable: signals.tcpUnreachable,
                failMessage: "TCP probe failed",
                passMessage: "TCP probe passed",
            ),
        )
        return checks
    }

    private static func serviceCheck(_ service: WorkloadServiceObservation) -> WorkloadHealthCheck {
        let name = "service:\(service.name)"
        if service.role == WorkloadServiceObservation.roleOneShot {
            if service.running {
                return WorkloadHealthCheck(name: name, status: .skip, message: "one-shot still running")
            }
            if service.exitCode == 0 {
                return WorkloadHealthCheck(name: name, status: .pass, message: "one-shot succeeded")
            }
            let code = service.exitCode.map(String.init) ?? "unknown"
            return WorkloadHealthCheck(name: name, status: .fail, message: "one-shot exited \(code)")
        }
        if !service.running {
            return WorkloadHealthCheck(name: name, status: .fail, message: "service is not running")
        }
        switch service.health {
        case "healthy":
            return WorkloadHealthCheck(name: name, status: .pass, message: "service healthy")
        case "unhealthy":
            return WorkloadHealthCheck(name: name, status: .fail, message: "service unhealthy")
        default:
            return WorkloadHealthCheck(name: name, status: .skip, message: "service running")
        }
    }

    private static func applicationRollup(
        state: VMState,
        signals: WorkloadHealthSignals,
        services: [WorkloadServiceObservation],
    ) -> (WorkloadHealth, String?) {
        if state == .error {
            return (.failed, signals.lastError ?? "application entered error state")
        }
        if signals.probesFailed {
            return (.degraded, probeFailMessage(signals))
        }
        let longRunning = services.filter { $0.role != WorkloadServiceObservation.roleOneShot }
        let oneShots = services.filter { $0.role == WorkloadServiceObservation.roleOneShot }
        let failedOneShot = oneShots.contains { !$0.running && $0.exitCode != 0 }
        let stoppedRequired = longRunning.contains { !$0.running }
        let unhealthy = longRunning.contains { $0.running && $0.health == "unhealthy" }
        if failedOneShot || stoppedRequired || unhealthy {
            let running = longRunning.contains { $0.running }
            if running {
                return (.degraded, "a required service is not healthy")
            }
            return (.failed, "a required service is not healthy")
        }
        let explicit = servicesExplicitlyHealthy(longRunning: longRunning, oneShots: oneShots)
        if explicit, longRunning.contains(where: \.running) {
            return (.guestReady, nil)
        }
        switch state {
        case .stopped, .deleting:
            return (.stopped, nil)
        case .starting, .provisioning:
            return (.starting, nil)
        case .stopping, .running:
            return (.running, nil)
        case .error:
            return (.failed, signals.lastError ?? "application entered error state")
        }
    }

    private static func servicesExplicitlyHealthy(
        longRunning: [WorkloadServiceObservation],
        oneShots: [WorkloadServiceObservation],
    ) -> Bool {
        if longRunning.isEmpty && oneShots.isEmpty { return false }
        let oneShotsDone = oneShots.allSatisfy { !$0.running && $0.exitCode == 0 }
        if !oneShotsDone { return false }
        if longRunning.isEmpty { return true }
        return longRunning.allSatisfy { $0.running && $0.health == "healthy" }
    }

    private static func distinguish(
        kind: String,
        state: VMState,
        signals: WorkloadHealthSignals,
        services: [WorkloadServiceObservation],
        health: WorkloadHealth,
        now: Date,
    ) -> (running: Bool, readiness: String, condition: String) {
        if kind == WorkloadSpec.kindApplication {
            return applicationFacts(state: state, services: services, health: health)
        }
        let processUp = state == .running && signals.qemuProcess != false
        let running = processUp || state == .starting
        let ready = processUp && signals.qmp != false && !signals.probesFailed
            && (signals.probesPassed || isGuestAgentFresh(signals, now: now) || !signals.probesConfigured)
        let condition: String = if state == .error || signals.qemuProcess == false || signals.qmp == false
            || signals.probesFailed
        {
            "unhealthy"
        } else if isGuestAgentFresh(signals, now: now) || signals.probesPassed {
            "healthy"
        } else {
            "unknown"
        }
        let readiness = if ready && (condition == "healthy" || !signals.probesConfigured && signals.qmp == true) {
            "ready"
        } else if state == .stopped || state == .error || signals.qemuProcess == false {
            "not_ready"
        } else {
            "unknown"
        }
        return (running, readiness, condition)
    }

    private static func applicationFacts(
        state: VMState,
        services: [WorkloadServiceObservation],
        health: WorkloadHealth,
    ) -> (running: Bool, readiness: String, condition: String) {
        let longRunning = services.filter { $0.role != WorkloadServiceObservation.roleOneShot }
        let oneShots = services.filter { $0.role == WorkloadServiceObservation.roleOneShot }
        let running = if services.isEmpty {
            state == .running || state == .starting
        } else {
            longRunning.contains { $0.running }
        }
        let explicit = servicesExplicitlyHealthy(longRunning: longRunning, oneShots: oneShots)
        let failed = health == .failed || health == .degraded
        let condition = if explicit {
            "healthy"
        } else if failed {
            "unhealthy"
        } else {
            "unknown"
        }
        let readiness = if condition == "healthy" {
            "ready"
        } else if condition == "unhealthy" {
            "not_ready"
        } else {
            "unknown"
        }
        return (running, readiness, condition)
    }

    public static func resolvedFreshness(stored: String, observedAt: String?, now: Date) -> String {
        if stored == "stale" { return "stale" }
        guard stored == "fresh", let observedAt, let seen = iso8601.date(from: observedAt) else {
            return stored == "fresh" ? "unknown" : stored
        }
        if now.timeIntervalSince(seen) > observationStaleAfter { return "stale" }
        return "fresh"
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
