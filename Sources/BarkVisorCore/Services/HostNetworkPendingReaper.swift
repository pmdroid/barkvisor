import Foundation
import GRDB
#if os(Linux)
    import Glibc
#endif

/// Seam for the one step in a reap that writes the host. Injectable so a test can observe
/// whether the reaper decided to revert, without touching real networking.
public struct HostNetworkReapOptions {
    public var revertHost: (HostNetworkPendingCommit, Int) throws -> Void

    public init(
        revertHost: @escaping (HostNetworkPendingCommit, Int) throws -> Void = { pending, attached in
            try HostNetworkPendingReaper.revertHost(pending, attached: attached)
        },
    ) {
        self.revertHost = revertHost
    }
}

public enum HostNetworkPendingReaper {
    public static func expire(
        db: DatabasePool,
        dataDir: URL = Config.dataDir,
        options: HostNetworkReapOptions = HostNetworkReapOptions(),
    ) async {
        let pendings = pendingWithoutStamp(dataDir: dataDir)
        let records = HostNetworkRecovery.list(dataDir: dataDir)
        for target in expireTargets(pendings: pendings, records: records) {
            if !HostNetworkPendingCommitService.stampExists(target, dataDir: dataDir) {
                for pending in pendings where pending.target == target && pending.expired {
                    await expirePending(pending, db: db, dataDir: dataDir, options: options)
                }
            }
            // The sweep restores snapshots under the same gate, and re-reads ownership
            // inside it, so it does not need the per-target claim held across this call.
            HostNetworkRecovery.sweepExpired(
                dataDir: dataDir,
                now: Date(),
                target: target,
                options: HostNetworkRecoverySweepOptions(
                    pendingCommits: pendings,
                    // Reports false when another holder owns the target's revert claim,
                    // so the sweep leaves the record retryable instead of settling a
                    // restore that never ran.
                    exclusive: { body in
                        try HostNetworkPendingCommitService.withHostMutationGate(
                            target: target,
                            dataDir: dataDir,
                        ) { try body() } != nil
                    },
                ),
            )
        }
    }

    /// Targets with expired work, from both pending commits and recovery records, so a
    /// record is still settled after its pending commit file is gone. Settled and
    /// unexpired records claim no gate: this runs every two seconds.
    public static func expireTargets(
        pendings: [HostNetworkPendingCommit],
        records: [HostNetworkRecoveryRecord],
        now: Date = Date(),
    ) -> [String] {
        var targets: [String] = []
        for pending in pendings where pending.expired && !targets.contains(pending.target) {
            targets.append(pending.target)
        }
        for record in records
            where !HostNetworkRecoveryPhase.isTerminal(record.phase)
            && now >= record.deadline
            && !targets.contains(record.target) {
            targets.append(record.target)
        }
        return targets
    }

    private static func expirePending(
        _ pending: HostNetworkPendingCommit,
        db: DatabasePool,
        dataDir: URL,
        options: HostNetworkReapOptions,
    ) async {
        do {
            let bridge = workloadBridgeName(pending)
            let attached = try await pending.createdBridge
                ? (NetworkService.attachedWorkloadCount(bridge: bridge, db: db))
                : 0
            if try await settleExpired(pending, db: db, dataDir: dataDir) {
                return
            }
            guard PendingNetworkUsePolicy.expiryAction(attachedWorkloads: attached) == .revert else {
                return
            }
            // The ownership check and the host revert share one exclusion with applies, in
            // the same lock order an apply uses. Re-reading the records before the gate
            // would still leave a window for an apply on another target to write a record
            // and its files in between, and deleting a file the record sweep cannot restore
            // is the worse failure.
            let reverted = try HostNetworkPendingCommitService.withHostMutationGate(
                target: pending.target,
                dataDir: dataDir,
            ) {
                // Re-check after taking the gate: an apply that landed while we waited
                // owns these paths now.
                guard !HostNetworkPendingCommitService.stampExists(pending.target, dataDir: dataDir) else {
                    return false
                }
                let fresh = HostNetworkRecovery.list(dataDir: dataDir)
                guard !hostMutationBlocked(pending, records: fresh, dataDir: dataDir) else {
                    return false
                }
                try options.revertHost(pending, attached)
                return true
            } ?? false
            guard reverted else { return }
            let still = try await pending.createdBridge
                ? (NetworkService.attachedWorkloadCount(bridge: bridge, db: db))
                : 0
            if LinuxHostBridgeApply.shouldDeleteWorkloadNetwork(
                createdBridge: pending.createdBridge,
                attached: still,
            ) {
                try await NetworkService.deleteUnattached(bridge: bridge, db: db)
            }
        } catch {
            return
        }
    }

    public static func settleExpired(
        _ pending: HostNetworkPendingCommit,
        db _: DatabasePool,
        dataDir: URL = Config.dataDir,
    ) async throws -> Bool {
        #if os(Linux)
            guard let pid = pending.netplanPid, pid > 0 else { return false }
            let alive = kill(pid_t(pid), 0) == 0
            switch LinuxHostBridgeApply.netplanExpireAction(
                pidAlive: alive,
                pidIsNetplan: LinuxHostBridgeApply.isNetplanProcess(pid: pid),
                keeping: HostNetworkPendingCommitService.keepingExists(pending.target, dataDir: dataDir),
            ) {
            case .waitForTry:
                return true
            case .stampKeep:
                try HostNetworkPendingCommitService.keepNow(target: pending.target)
                return true
            case .alreadyReverted:
                return false
            }
        #else
            return false
        #endif
    }

    /// True when a *newer* recovery record claims a path this pending's revert would
    /// remove, so reverting would delete files the newer apply owns.
    ///
    /// On systemd-networkd a revert deletes `90-barkvisor-<bridge>.netdev`,
    /// `90-barkvisor-<bridge>.network` and the shared uplink unit
    /// `90-barkvisor-<nic>.network`, and every bridge snapshot also claims the fixed
    /// `90-barkvisor-br0.*` units, so two different targets routinely share paths.
    ///
    /// Only a newer claim blocks. An older confirmed record shares those same paths but
    /// was already applied and kept, so blocking on it would leave an expired bridge
    /// configured forever. A pending that cannot be placed in apply order blocks on any
    /// claim, because then nothing proves it is the newer of the pair.
    public static func hostMutationBlocked(
        _ pending: HostNetworkPendingCommit,
        records: [HostNetworkRecoveryRecord],
        dataDir: URL = Config.dataDir,
    ) -> Bool {
        let paths = mutationPaths(for: pending, records: records)
        guard !paths.isEmpty else { return false }
        let rivals = records.filter { record in
            record.operationId != pending.operationId
                && record.phase != HostNetworkRecoveryPhase.superseded
                && !record.claimedPaths.isDisjoint(with: paths)
        }
        guard !rivals.isEmpty else { return false }
        guard let mine = applyOrder(of: pending, records: records, dataDir: dataDir) else {
            return true
        }
        return rivals.contains { record in
            let theirs = HostNetworkRecoveryOwnership.Order(
                startedAt: record.startedAt,
                operationId: record.operationId,
            )
            return HostNetworkRecoveryOwnership.Order.isNewer(theirs, than: mine)
                || !HostNetworkRecoveryOwnership.Order.isConfidentlyOrdered(theirs, mine)
        }
    }

    /// Where this pending sits in apply order. Its own recovery record carries the apply
    /// timestamp; without one, the pending file's own modification date is the next best
    /// durable proxy, since that file is written when the apply runs and removed on commit.
    /// Nil when neither is available, which the caller treats as unorderable.
    static func applyOrder(
        of pending: HostNetworkPendingCommit,
        records: [HostNetworkRecoveryRecord],
        dataDir: URL,
    ) -> HostNetworkRecoveryOwnership.Order? {
        let operationId = pending.operationId ?? "pending-\(pending.target)"
        if let record = records.first(where: { $0.operationId == operationId }), record.startedAt != nil {
            return HostNetworkRecoveryOwnership.Order(
                startedAt: record.startedAt,
                operationId: operationId,
            )
        }
        guard let modified = pendingFileModified(target: pending.target, dataDir: dataDir) else {
            return nil
        }
        return HostNetworkRecoveryOwnership.Order(startedAt: modified, operationId: operationId)
    }

    private static func pendingFileModified(target: String, dataDir: URL) -> Date? {
        let linux = URL(fileURLWithPath: HostNetworkPendingCommitService.linuxPendingPath(
            bridge: target,
            dataDir: dataDir,
        ))
        let mac = HostNetworkPendingCommitService.macPendingURL(device: target, dataDir: dataDir)
        for url in [linux, mac] {
            if let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                as? Date {
                return modified
            }
        }
        return nil
    }

    /// The host paths a pending revert would touch. Its own recovery record is the same
    /// source of truth the record sweep uses, so the two agree by construction; a pending
    /// with no record falls back to the bridge's canonical unit paths.
    static func mutationPaths(
        for pending: HostNetworkPendingCommit,
        records: [HostNetworkRecoveryRecord],
    ) -> Set<String> {
        if let operationId = pending.operationId,
           let record = records.first(where: { $0.operationId == operationId }) {
            return record.claimedPaths
        }
        let bridge = workloadBridgeName(pending)
        let nic = LinuxHostBridgeApply.readOwnerMarker(bridge: pending.target)?.uplink ?? pending.target
        return [
            LinuxHostBridgeApply.netplanPath(bridge: bridge),
            LinuxHostBridgeApply.networkdNetdevPath(bridge: bridge),
            LinuxHostBridgeApply.networkdNetworkPath(bridge: bridge),
            LinuxHostBridgeApply.networkdPortPath(nic: nic),
        ]
    }

    public static func pendingWithoutStamp(dataDir: URL = Config.dataDir) -> [HostNetworkPendingCommit] {
        HostNetworkPendingCommitService.listPending(dataDir: dataDir)
            .filter { !HostNetworkPendingCommitService.stampExists($0.target, dataDir: dataDir) }
    }

    public static func revertHost(_ pending: HostNetworkPendingCommit, attached: Int = 0) throws {
        let action: LinuxHostBridgeApplyAction = pending.createdBridge ? .delete : .revert
        let nic = LinuxHostBridgeApply.readOwnerMarker(bridge: pending.target)?.uplink
            ?? pending.target
        let request = LinuxHostBridgeApplyRequest(
            action: action,
            bridge: workloadBridgeName(pending),
            nic: nic,
            confirm: true,
            attachedWorkloadCount: attached,
            unconfirmedExpiry: true,
            operationId: pending.operationId,
            generation: pending.generation,
        )
        #if os(Linux)
            _ = try LinuxHostBridgeApplyLive.run(request: request)
        #elseif os(macOS)
            _ = try MacHostBridgeApplyLive.run(request: request)
        #else
            throw BarkVisorError.forbidden("Host network revert is not available.")
        #endif
    }

    private static func workloadBridgeName(_ pending: HostNetworkPendingCommit) -> String {
        if pending.createdBridge {
            if let marker = LinuxHostBridgeApply.readOwnerMarker(bridge: pending.target) {
                return marker.bridge
            }
            let fromUplink = LinuxHostBridgeApply.listOwnerMarkers().first { $0.uplink == pending.target }
            return fromUplink?.bridge ?? pending.target
        }
        return pending.target
    }
}
