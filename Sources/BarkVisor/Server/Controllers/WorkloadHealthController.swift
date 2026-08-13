import BarkVisorCore
import Foundation
import GRDB
import Vapor

/// `GET /api/workloads/health-summary` (PAS-79). VMs only in Wave 0.
struct WorkloadHealthController: RouteCollection {
    let vmManager: VMManager

    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "workloads", "health-summary", use: summary)
    }

    @Sendable
    func summary(req: Vapor.Request) async throws -> WorkloadHealthSummary {
        let vms = try await req.db.read { db in
            try VM.fetchAll(db)
        }
        let lastSeen = try await guestLastSeen(ids: vms.map(\.id), db: req.db)
        var items: [WorkloadHealthSummaryItem] = []
        items.reserveCapacity(vms.count)
        for vm in vms {
            let signals = await vmManager.healthSignals(for: vm, lastSeenAt: lastSeen[vm.id])
            let status = WorkloadHealthProjector.project(
                state: VMState.parse(vm.state),
                signals: signals,
                updatedAt: vm.updatedAt,
            )
            items.append(
                WorkloadHealthSummaryItem(
                    id: vm.id,
                    name: vm.name,
                    kind: "vm",
                    health: status.health,
                    lastError: status.lastError,
                ),
            )
        }
        return WorkloadHealthProjector.summarize(
            items: items,
            updatedAt: iso8601.string(from: Date()),
        )
    }

    private func guestLastSeen(ids: [String], db: DatabasePool) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let records = try await db.read { db in
            try GuestInfoRecord.fetchAll(db)
        }
        var seen: [String: String] = [:]
        for record in records where idSet.contains(record.vmId) {
            seen[record.vmId] = record.updatedAt
        }
        return seen
    }
}
