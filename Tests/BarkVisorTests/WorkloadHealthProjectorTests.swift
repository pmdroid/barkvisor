import Foundation
import Testing
@testable import BarkVisorCore

@Suite("WorkloadHealthProjector")
struct WorkloadHealthProjectorTests {
    private let now = "2026-08-12T00:00:00Z"

    @Test func `stopped maps to stopped`() {
        let status = WorkloadHealthProjector.project(state: .stopped, updatedAt: now)
        #expect(status.health == .stopped)
        #expect(status.lastError == nil)
        #expect(status.checks.contains { $0.name == "guestAgent" && $0.status == .skip })
    }

    @Test func `starting maps to starting`() {
        let status = WorkloadHealthProjector.project(state: .starting, updatedAt: now)
        #expect(status.health == .starting)
    }

    @Test func `running without guest agent is running not failed`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(qemuProcess: true, qmp: true, guestAgent: false),
            updatedAt: now,
        )
        #expect(status.health == .running)
        #expect(status.lastError == nil)
        #expect(status.checks.contains { $0.name == "guestAgent" && $0.status == .skip })
        #expect(status.checks.contains { $0.name == "qemuProcess" && $0.status == .pass })
        #expect(!status.checks.contains { $0.name == "guestAgent" && $0.status == .fail })
    }

    @Test func `running with unobserved signals is still running`() {
        let status = WorkloadHealthProjector.project(state: .running, updatedAt: now)
        #expect(status.health == .running)
        #expect(status.checks.contains { $0.name == "qemuProcess" && $0.status == .skip })
    }

    @Test func `error state is failed with last error`() {
        let status = WorkloadHealthProjector.project(
            state: .error,
            signals: WorkloadHealthSignals(lastError: "QEMU exited with status 1"),
            updatedAt: now,
        )
        #expect(status.health == .failed)
        #expect(status.lastError == "QEMU exited with status 1")
    }

    @Test func `error state without cached error uses fallback`() {
        let status = WorkloadHealthProjector.project(state: .error, updatedAt: now)
        #expect(status.health == .failed)
        #expect(status.lastError == "QEMU entered error state")
    }

    @Test func `dead qemu process while running is failed`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(qemuProcess: false, qmp: false),
            updatedAt: now,
        )
        #expect(status.health == .failed)
        #expect(status.lastError == "QEMU process not running")
        #expect(status.checks.contains { $0.name == "qemuProcess" && $0.status == .fail })
    }

    @Test func `qmp down while process up is degraded`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(qemuProcess: true, qmp: false),
            updatedAt: now,
        )
        #expect(status.health == .degraded)
        #expect(status.lastError == "QMP unreachable")
    }

    @Test func `fresh guest agent is guest_ready`() {
        let clock = iso8601.date(from: now) ?? Date()
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                guestAgent: true,
                lastSeenAt: now,
            ),
            updatedAt: now,
            now: clock,
        )
        #expect(status.health == .guestReady)
        #expect(status.checks.contains { $0.name == "guestAgent" && $0.status == .pass })
    }

    @Test func `stale guest agent stays running`() {
        let clock = iso8601.date(from: now) ?? Date()
        let stale = iso8601.string(from: clock.addingTimeInterval(-180))
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                guestAgent: true,
                lastSeenAt: stale,
            ),
            updatedAt: now,
            now: clock,
        )
        #expect(status.health == .running)
        #expect(status.checks.contains { $0.name == "guestAgent" && $0.status == .skip })
        #expect(status.checks.contains { $0.name == "http" && $0.status == .skip })
    }

    @Test func `passing http probe is guest_ready without guest agent`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                http: true,
                httpConfigured: true,
            ),
            updatedAt: now,
        )
        #expect(status.health == .guestReady)
        #expect(status.checks.contains { $0.name == "http" && $0.status == .pass })
        #expect(status.checks.contains { $0.name == "guestAgent" && $0.status == .skip })
    }

    @Test func `failed http probe is degraded`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                guestAgent: true,
                lastSeenAt: now,
                http: false,
                httpConfigured: true,
            ),
            updatedAt: now,
            now: iso8601.date(from: now) ?? Date(),
        )
        #expect(status.health == .degraded)
        #expect(status.lastError == "HTTP probe failed")
        #expect(status.checks.contains { $0.name == "http" && $0.status == .fail })
    }

    @Test func `configured but unobserved probe stays running`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                httpConfigured: true,
            ),
            updatedAt: now,
        )
        #expect(status.health == .running)
        #expect(status.checks.contains { $0.name == "http" && $0.status == .skip })
    }

    @Test func `http pass with unobserved tcp stays running`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                http: true,
                httpConfigured: true,
                tcpConfigured: true,
            ),
            updatedAt: now,
        )
        #expect(status.health == .running)
        #expect(status.checks.contains { $0.name == "http" && $0.status == .pass })
        #expect(status.checks.contains { $0.name == "tcp" && $0.status == .skip })
    }

    @Test func `http and tcp both passing is guest_ready`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                http: true,
                tcp: true,
                httpConfigured: true,
                tcpConfigured: true,
            ),
            updatedAt: now,
        )
        #expect(status.health == .guestReady)
        #expect(status.checks.contains { $0.name == "http" && $0.status == .pass })
        #expect(status.checks.contains { $0.name == "tcp" && $0.status == .pass })
    }

    @Test func `unreachable probe is skip not guest_ready`() {
        let status = WorkloadHealthProjector.project(
            state: .running,
            signals: WorkloadHealthSignals(
                qemuProcess: true,
                qmp: true,
                http: true,
                httpConfigured: true,
                tcpConfigured: true,
                tcpUnreachable: true,
            ),
            updatedAt: now,
        )
        #expect(status.health == .running)
        #expect(status.checks.contains {
            $0.name == "tcp" && $0.status == .skip && $0.message == "unreachable target"
        })
    }

    @Test func `summary counts every health case`() {
        let items = [
            WorkloadHealthSummaryItem(id: "a", name: "one", health: .running),
            WorkloadHealthSummaryItem(id: "b", name: "two", health: .failed, lastError: "boom"),
            WorkloadHealthSummaryItem(id: "c", name: "three", health: .running),
        ]
        let summary = WorkloadHealthProjector.summarize(items: items, updatedAt: now)
        #expect(summary.counts["running"] == 2)
        #expect(summary.counts["failed"] == 1)
        #expect(summary.counts["guest_ready"] == 0)
        #expect(summary.counts["stopped"] == 0)
        #expect(summary.items.count == 3)
        #expect(WorkloadHealth.allCases.allSatisfy { summary.counts[$0.rawValue] != nil })
    }

    @Test func `process health db failure is error`() {
        let status = WorkloadHealthProjector.processHealth(
            checks: [
                WorkloadHealthCheck(name: "database", status: .fail, message: "down"),
                WorkloadHealthCheck(name: "dataDir", status: .pass),
            ],
            updatedAt: now,
        )
        #expect(status.status == "error")
        #expect(status.apiVersion == APIContract.version)
    }

    @Test func `process health extra failure is degraded`() {
        let status = WorkloadHealthProjector.processHealth(
            checks: [
                WorkloadHealthCheck(name: "database", status: .pass),
                WorkloadHealthCheck(name: "dataDir", status: .fail, message: "ro"),
            ],
            updatedAt: now,
        )
        #expect(status.status == "degraded")
    }

    @Test func `process health all pass is ok`() {
        let status = WorkloadHealthProjector.processHealth(
            checks: [
                WorkloadHealthCheck(name: "database", status: .pass),
                WorkloadHealthCheck(name: "qemu", status: .skip),
            ],
            updatedAt: now,
        )
        #expect(status.status == "ok")
        #expect(status.apiVersion == APIContract.version)
    }

    @Test func `health enum encodes guest_ready snake case`() throws {
        let data = try JSONEncoder().encode(WorkloadHealth.guestReady)
        #expect(String(data: data, encoding: .utf8) == "\"guest_ready\"")
    }
}
