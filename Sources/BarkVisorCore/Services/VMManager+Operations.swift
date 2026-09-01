import Foundation
import GRDB

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

            var updated = vm
            if let isoId {
                var ids = updated.decodedISOIds
                ids.removeAll { $0 == isoId }
                updated.setISOIds(ids.isEmpty ? nil : ids)
            } else {
                updated.setISOIds(nil)
            }

            updated.updatedAt = now
            if isRunning { updated.pendingChanges = true }
            updated.syncSpecProjection(bumpGeneration: true)
            try updated.update(db)
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
            guard let image = try VMImage.fetchOne(db, key: isoId) else {
                throw BarkVisorError.notFound("ISO image not found")
            }
            guard image.imageType == "iso" else {
                throw BarkVisorError.badRequest("Image is not an ISO")
            }
            guard image.status == "ready" else {
                throw BarkVisorError.badRequest("ISO is not ready")
            }
            guard let vm = try VM.fetchOne(db, key: vmID) else {
                throw BarkVisorError.notFound("VM not found")
            }

            var updated = vm
            var ids = updated.decodedISOIds
            guard !ids.contains(isoId) else { return } // already attached
            ids.append(isoId)
            updated.setISOIds(ids)

            let now = iso8601.string(from: Date())
            updated.updatedAt = now
            if isRunning { updated.pendingChanges = true }
            updated.syncSpecProjection(bumpGeneration: true)
            try updated.update(db)
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

    public func recordHealthError(_ message: String, for vmID: String) {
        lastHealthErrors[vmID] = message
    }

    public func clearHealthError(for vmID: String) {
        lastHealthErrors.removeValue(forKey: vmID)
    }

    public func healthError(for vmID: String) -> String? {
        lastHealthErrors[vmID]
    }

    /// Live PAS-79/65 signals from the process table, QMP socket, guest_info, and probes.
    public func healthSignals(
        for vm: VM,
        lastSeenAt: String?,
        probes: HealthProbeResults = .unobserved,
    ) -> WorkloadHealthSignals {
        let state = VMState.parse(vm.state)
        let lastError = lastHealthErrors[vm.id]
        if let running = runningVMs[vm.id] {
            return WorkloadHealthSignals(
                qemuProcess: isProcessAlive(running),
                qmp: FileManager.default.fileExists(atPath: running.qmpSocketPath),
                guestAgent: lastSeenAt != nil,
                lastSeenAt: lastSeenAt,
                lastError: lastError,
                http: probes.http,
                tcp: probes.tcp,
                httpConfigured: probes.httpConfigured,
                tcpConfigured: probes.tcpConfigured,
                httpUnreachable: probes.httpUnreachable,
                tcpUnreachable: probes.tcpUnreachable,
            )
        }
        if state == .running {
            return WorkloadHealthSignals(
                qemuProcess: false,
                qmp: false,
                guestAgent: lastSeenAt != nil,
                lastSeenAt: lastSeenAt,
                lastError: lastError ?? "QEMU process not running",
                http: probes.http,
                tcp: probes.tcp,
                httpConfigured: probes.httpConfigured,
                tcpConfigured: probes.tcpConfigured,
                httpUnreachable: probes.httpUnreachable,
                tcpUnreachable: probes.tcpUnreachable,
            )
        }
        return WorkloadHealthSignals(
            guestAgent: lastSeenAt != nil,
            lastSeenAt: lastSeenAt,
            lastError: lastError,
            http: probes.http,
            tcp: probes.tcp,
            httpConfigured: probes.httpConfigured,
            tcpConfigured: probes.tcpConfigured,
            httpUnreachable: probes.httpUnreachable,
            tcpUnreachable: probes.tcpUnreachable,
        )
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
            // Load ISOs via typed accessor (includes legacy isoId fallback).
            var isos: [VMImage] = []
            for isoId in vm.decodedISOIds {
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
            var additionalDisks: [Disk] = []
            for diskId in vm.decodedAdditionalDiskIds {
                if let d = try Disk.fetchOne(db, key: diskId) {
                    additionalDisks.append(d)
                }
            }
            return VMLoadResult(vm: vm, disk: disk, isos: isos, network: network, additionalDisks: additionalDisks)
        }
    }
}
