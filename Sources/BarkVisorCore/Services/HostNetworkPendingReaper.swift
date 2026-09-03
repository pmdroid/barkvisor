import Foundation
import GRDB
#if os(Linux)
    import Glibc
#endif

public enum HostNetworkPendingReaper {
    public static func expire(db: DatabasePool) async {
        for pending in pendingWithoutStamp() {
            guard pending.expired else { continue }
            guard HostNetworkPendingCommitService.claimRevert(pending.target) else { continue }
            defer { HostNetworkPendingCommitService.releaseRevert(pending.target) }
            if HostNetworkPendingCommitService.stampExists(pending.target) {
                continue
            }
            do {
                let bridge = workloadBridgeName(pending)
                let attached = pending.createdBridge
                    ? (try await NetworkService.attachedWorkloadCount(bridge: bridge, db: db))
                    : 0
                if attached > 0 {
                    keepNetplanTry(pending)
                    try HostNetworkPendingCommitService.keepNow(target: pending.target)
                    continue
                }
                if try await settleExpired(pending, db: db) {
                    continue
                }
                try revertHost(pending, attached: attached)
                let still = pending.createdBridge
                    ? (try await NetworkService.attachedWorkloadCount(bridge: bridge, db: db))
                    : 0
                if LinuxHostBridgeApply.shouldDeleteWorkloadNetwork(
                    createdBridge: pending.createdBridge,
                    attached: still,
                ) {
                    try await NetworkService.deleteUnattached(bridge: bridge, db: db)
                }
            } catch {
                continue
            }
        }
    }

    public static func settleExpired(
        _ pending: HostNetworkPendingCommit,
        db _: DatabasePool,
    ) async throws -> Bool {
        #if os(Linux)
            guard let pid = pending.netplanPid, pid > 0 else { return false }
            let alive = kill(pid_t(pid), 0) == 0
            switch LinuxHostBridgeApply.netplanExpireAction(
                pidAlive: alive,
                pidIsNetplan: LinuxHostBridgeApply.isNetplanProcess(pid: pid),
                keeping: HostNetworkPendingCommitService.keepingExists(pending.target),
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

    public static func pendingWithoutStamp() -> [HostNetworkPendingCommit] {
        #if os(Linux)
            return HostNetworkPendingCommitService.listLinuxPending()
                .filter { !HostNetworkPendingCommitService.stampExists($0.target) }
        #elseif os(macOS)
            return HostNetworkPendingCommitService.listMacPending()
                .filter { !HostNetworkPendingCommitService.stampExists($0.target) }
        #else
            return []
        #endif
    }

    private static func keepNetplanTry(_ pending: HostNetworkPendingCommit) {
        #if os(Linux)
            guard let pid = pending.netplanPid, pid > 0 else { return }
            guard LinuxHostBridgeApply.isNetplanProcess(pid: pid) else { return }
            _ = kill(pid_t(pid), SIGUSR1)
        #endif
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
