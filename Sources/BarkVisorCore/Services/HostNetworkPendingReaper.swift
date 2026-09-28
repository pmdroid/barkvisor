import Foundation
import GRDB
#if os(Linux)
    import Glibc
#endif

public enum HostNetworkPendingReaper {
    public static func expire(db: DatabasePool, dataDir: URL = Config.dataDir) async {
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
            for pending in pendings where pending.target == target && pending.expired {
                await expirePending(pending, db: db, dataDir: dataDir)
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
            try revertHost(pending, attached: attached)
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
