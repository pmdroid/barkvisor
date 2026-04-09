import Foundation
import GRDB
import os

extension VMManager {
    // MARK: - Detach ISO

    /// Detach a specific ISO from a VM, or all ISOs if isoId is nil.
    public func detachISO(vmID: String, isoId: String? = nil) async throws {
        let isRunning = runningVMs[vmID] != nil

        try await dbPool.write { db in
            let now = iso8601.string(from: Date())
            guard let vm = try VM.fetchOne(db, key: vmID) else {
                throw BarkVisorError.notFound("VM not found")
            }

            let newIsoIds: [String]?
            if let isoId {
                // Remove specific ISO
                var ids = JSONColumnCoding.decodeArray(String.self, from: vm.isoIds) ?? []
                ids.removeAll { $0 == isoId }
                newIsoIds = ids.isEmpty ? nil : ids
            } else {
                // Detach all
                newIsoIds = nil
            }

            let isoIdsJSON = JSONColumnCoding.encode(newIsoIds)
            if isRunning {
                try db.execute(
                    sql:
                    "UPDATE vms SET isoId = NULL, isoIds = ?, pendingChanges = 1, updatedAt = ? WHERE id = ?",
                    arguments: [isoIdsJSON, now, vmID],
                )
            } else {
                try db.execute(
                    sql: "UPDATE vms SET isoId = NULL, isoIds = ?, updatedAt = ? WHERE id = ?",
                    arguments: [isoIdsJSON, now, vmID],
                )
            }
        }

        if isRunning {
            let event = VMStateEvent(id: vmID, state: "running", error: nil)
            await stateStreamService?.broadcast(event: event)
        }
    }

    // MARK: - Attach ISO

    /// Attach an ISO to a VM by appending it to the isoIds array.
    public func attachISO(vmID: String, isoId: String) async throws {
        let isRunning = runningVMs[vmID] != nil

        try await dbPool.write { db in
            // Validate the ISO exists
            guard try VMImage.fetchOne(db, key: isoId) != nil else {
                throw BarkVisorError.notFound("ISO image not found")
            }
            guard let vm = try VM.fetchOne(db, key: vmID) else {
                throw BarkVisorError.notFound("VM not found")
            }

            var ids = JSONColumnCoding.decodeArray(String.self, from: vm.isoIds) ?? []
            guard !ids.contains(isoId) else { return } // already attached
            ids.append(isoId)

            let now = iso8601.string(from: Date())
            let isoIdsJSON = JSONColumnCoding.encode(ids)
            if isRunning {
                try db.execute(
                    sql: "UPDATE vms SET isoIds = ?, pendingChanges = 1, updatedAt = ? WHERE id = ?",
                    arguments: [isoIdsJSON, now, vmID],
                )
            } else {
                try db.execute(
                    sql: "UPDATE vms SET isoIds = ?, updatedAt = ? WHERE id = ?",
                    arguments: [isoIdsJSON, now, vmID],
                )
            }
        }

        if isRunning {
            let event = VMStateEvent(id: vmID, state: "running", error: nil)
            await stateStreamService?.broadcast(event: event)
        }
    }

    // MARK: - Query

    public func isRunning(_ vmID: String) -> Bool {
        runningVMs[vmID] != nil
    }

    /// Check if a VM is currently starting or running in the actor.
    /// Used by delete handler to prevent TOCTOU races where DB state is stale.
    public func isActiveOrStarting(_ vmID: String) -> Bool {
        runningVMs[vmID] != nil || startingVMs.contains(vmID)
    }

    public func vncSocketPath(for vmID: String) -> String? {
        runningVMs[vmID]?.vncSocketPath
    }

    public func serialSocketPath(for vmID: String) -> String? {
        runningVMs[vmID]?.serialSocketPath
    }

    public func qmpSocketPath(for vmID: String) -> String? {
        runningVMs[vmID]?.qmpSocketPath
    }

    public func allRunningVMs() -> [String: RunningVM] {
        runningVMs
    }

    /// Get VM list for menu bar display
    public func vmList() async -> [VMInfo] {
        do {
            return try await dbPool.read { db in
                try VM.fetchAll(db).map { vm in
                    VMInfo(id: vm.id, name: vm.name, state: vm.state)
                }
            }
        } catch {
            Log.vm.error("Failed to fetch VM list: \(error)")
            return []
        }
    }

    // MARK: - State & DB Helpers

    public func updateState(vmID: String, state: String, error: String? = nil) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE vms SET state = ?, updatedAt = ? WHERE id = ?",
                arguments: [state, iso8601.string(from: Date()), vmID],
            )
        }

        let event = VMStateEvent(id: vmID, state: state, error: error)
        await stateStreamService?.broadcast(event: event)
    }

    func loadVM(id: String) async throws -> VMLoadResult {
        try await dbPool.read { db in
            guard let vm = try VM.fetchOne(db, key: id) else {
                throw BarkVisorError.vmNotRunning(id)
            }
            guard let disk = try Disk.fetchOne(db, key: vm.bootDiskId) else {
                throw BarkVisorError.diskCreateFailed("Boot disk \(vm.bootDiskId) not found")
            }
            // Load ISOs from isoIds (JSON array), falling back to legacy isoId
            var isos: [VMImage] = []
            let isoIdList =
                JSONColumnCoding.decodeArray(String.self, from: vm.isoIds)
                    ?? {
                        if let legacyId = vm.isoId { return [legacyId] }
                        return []
                    }()
            for isoId in isoIdList {
                if let image = try VMImage.fetchOne(db, key: isoId) {
                    isos.append(image)
                }
            }
            let network: Network? =
                if let netId = vm.networkId {
                    try Network.fetchOne(db, key: netId)
                } else {
                    nil
                }
            // Load additional disks
            var additionalDisks: [Disk] = []
            if let idsJSON = vm.additionalDiskIds,
               let idsData = idsJSON.data(using: .utf8) {
                let ids: [String]
                do {
                    ids = try JSONDecoder().decode([String].self, from: idsData)
                } catch {
                    Log.vm.error("Failed to decode additionalDiskIds for VM \(id): \(error)", vm: id)
                    ids = []
                }
                for diskId in ids {
                    if let d = try Disk.fetchOne(db, key: diskId) {
                        additionalDisks.append(d)
                    }
                }
            }
            return VMLoadResult(vm: vm, disk: disk, isos: isos, network: network, additionalDisks: additionalDisks)
        }
    }
}
