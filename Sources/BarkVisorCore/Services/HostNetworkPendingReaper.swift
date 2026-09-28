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
            var claimed = false
            defer {
                if claimed { HostNetworkPendingCommitService.releaseRevert(target, dataDir: dataDir) }
            }
            // Re-check after claiming: a commit that landed while we waited owns the target.
            if HostNetworkPendingCommitService.stampExists(target, dataDir: dataDir) { continue }
            claimed = HostNetworkPendingCommitService.claimRevert(target, dataDir: dataDir)
            guard claimed else { continue }
            if HostNetworkPendingCommitService.stampExists(target, dataDir: dataDir) { continue }
            // Re-read so a record that landed since the sweep started also blocks the
            // host mutation below.
            let current = HostNetworkRecovery.list(dataDir: dataDir)
            for pending in pendings where pending.target == target && pending.expired {
                // This revert deletes host files, and an expired pending can outlive a
                // newer apply on an overlapping target: the pending file is gone once that
                // apply runs, so nothing else stops this removal. The record sweep runs
                // afterwards and cannot undo a deletion.
                guard !hostMutationBlocked(pending, records: current) else { continue }
                await expirePending(pending, db: db, dataDir: dataDir, options: options)
            }
            // Release the target claim before the record sweep. The sweep takes the same
            // global apply gate an apply holds, and the apply path takes that gate *before*
            // the target claim, so holding a claim across the gate would invert the order
            // and can deadlock. The gate alone already excludes every apply, and the
            // sweep re-reads ownership inside it.
            HostNetworkPendingCommitService.releaseRevert(target, dataDir: dataDir)
            claimed = false
            HostNetworkRecovery.sweepExpired(
                dataDir: dataDir,
                now: Date(),
                target: target,
                options: HostNetworkRecoverySweepOptions(pendingCommits: pendings),
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
            try options.revertHost(pending, attached)
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

    /// True when another recovery record claims a path this pending's revert would remove.
    ///
    /// On systemd-networkd a revert deletes `90-barkvisor-<bridge>.netdev`,
    /// `90-barkvisor-<bridge>.network` and the shared uplink unit
    /// `90-barkvisor-<nic>.network`, and every bridge snapshot also claims the fixed
    /// `90-barkvisor-br0.*` units. So an expired pending for one bridge can delete files a
    /// newer confirmed apply on another bridge owns, and the record sweep that follows
    /// cannot restore a deleted file.
    ///
    /// Deliberately conservative: any other live claim blocks, not only a newer one. A
    /// pending commit carries no apply timestamp to order it against, and not deleting a
    /// host file is the safe direction. The common case, one apply with no competitor, is
    /// unaffected.
    public static func hostMutationBlocked(
        _ pending: HostNetworkPendingCommit,
        records: [HostNetworkRecoveryRecord],
    ) -> Bool {
        let paths = mutationPaths(for: pending, records: records)
        guard !paths.isEmpty else { return false }
        return records.contains { record in
            guard record.operationId != pending.operationId else { return false }
            guard record.phase != HostNetworkRecoveryPhase.superseded else { return false }
            return !record.claimedPaths.isDisjoint(with: paths)
        }
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
