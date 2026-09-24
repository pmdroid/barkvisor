import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// `GET /api/workloads/health-summary` (PAS-79 / PAS-65). VMs only.
struct WorkloadHealthController: RouteCollection {
    let vmManager: VMManager
    let healthProbes: HealthProbeService

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "workloads", "health-summary", use: summary)
    }

    @Sendable
    func summary(req: Vapor.Request) async throws -> WorkloadHealthSummary {
        let vms = try await req.db.read { db in
            try VM.fetchAll(db)
        }
        let lastSeen = try await GuestHealthStore.lastSeen(ids: vms.map(\.id), db: req.db)
        let observations = try await req.db.read { db in
            try WorkloadObservation.fetchAll(db)
        }
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        var items: [WorkloadHealthSummaryItem] = []
        items.reserveCapacity(vms.count)
        for vm in vms {
            let probes = await healthProbes.results(for: vm)
            let signals = await vmManager.healthSignals(
                for: vm, lastSeenAt: lastSeen[vm.id], probes: probes,
            )
            let stored = byID[vm.id]
            let status = WorkloadHealthProjector.project(
                state: VMState.parse(vm.state),
                signals: signals,
                updatedAt: vm.updatedAt,
                kind: vm.kind,
                services: stored?.services ?? [],
                observedAt: stored?.observedAt,
                freshness: stored?.freshness ?? "unknown",
                appliedGeneration: stored?.appliedGeneration,
            )
            items.append(
                WorkloadHealthSummaryItem(
                    id: vm.id,
                    name: vm.name,
                    kind: vm.kind,
                    health: status.health,
                    lastError: status.lastError,
                    running: status.running,
                    readiness: status.readiness,
                    condition: status.condition,
                    observation: status.observation,
                ),
            )
        }
        return WorkloadHealthProjector.summarize(
            items: items,
            updatedAt: iso8601.string(from: Date()),
        )
    }
}
