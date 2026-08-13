import BarkVisorCore
import Foundation
import GRDB
import Vapor

extension VMController {
    @Sendable
    func getHealth(req: Vapor.Request) async throws -> WorkloadHealthStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        return try await projectHealth(vm, db: req.db)
    }

    @Sendable
    func putHealth(req: Vapor.Request) async throws -> WorkloadHealthStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        let body = try req.content.decode(WorkloadHealthSpec.self)
        try WorkloadHealthSpec.validate(body)
        let vm = try await req.db.write { db -> VM in
            guard var vm = try VM.fetchOne(db, key: id) else {
                throw Abort(.notFound)
            }
            vm.setHealth(body)
            vm.updatedAt = iso8601.string(from: Date())
            vm.syncSpecProjection(bumpGeneration: true)
            try vm.update(db)
            return vm
        }
        await healthProbes.reset(vmID: vm.id)
        return try await projectHealth(vm, db: req.db)
    }

    @Sendable
    func probeHealth(req: Vapor.Request) async throws -> WorkloadHealthStatus {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        guard let vm = try await req.db.read({ db in try VM.fetchOne(db, key: id) }) else {
            throw Abort(.notFound)
        }
        let ips = await GuestHealthStore.ipsByVM(ids: [vm.id], db: req.db)
        _ = await healthProbes.probeNow(vm: vm, guestIPs: ips[vm.id] ?? [])
        return try await projectHealth(vm, db: req.db)
    }

    func respond(_ vm: VM, db: DatabasePool) async throws -> VMResponse {
        let signals = try await healthSignals(for: vm, db: db)
        return VMResponse(from: vm, signals: signals)
    }

    func respond(_ vms: [VM], db: DatabasePool) async throws -> [VMResponse] {
        let lastSeen = try await GuestHealthStore.lastSeen(ids: vms.map(\.id), db: db)
        var responses: [VMResponse] = []
        responses.reserveCapacity(vms.count)
        for vm in vms {
            let probes = await healthProbes.results(for: vm)
            let signals = await vmManager.healthSignals(
                for: vm, lastSeenAt: lastSeen[vm.id], probes: probes,
            )
            responses.append(VMResponse(from: vm, signals: signals))
        }
        return responses
    }

    private func projectHealth(_ vm: VM, db: DatabasePool) async throws -> WorkloadHealthStatus {
        let signals = try await healthSignals(for: vm, db: db)
        return WorkloadHealthProjector.project(
            state: VMState.parse(vm.state),
            signals: signals,
            updatedAt: vm.updatedAt,
        )
    }

    private func healthSignals(for vm: VM, db: DatabasePool) async throws -> WorkloadHealthSignals {
        let lastSeen = try await GuestHealthStore.lastSeen(ids: [vm.id], db: db)
        let probes = await healthProbes.results(for: vm)
        return await vmManager.healthSignals(
            for: vm, lastSeenAt: lastSeen[vm.id], probes: probes,
        )
    }
}
