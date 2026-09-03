import Foundation
import GRDB

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
                try revertHost(pending)
                let bridge = workloadBridgeName(pending)
                try await NetworkService.deleteUnattached(bridge: bridge, db: db)
            } catch {
                continue
            }
        }
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

    public static func revertHost(_ pending: HostNetworkPendingCommit) throws {
        let action: LinuxHostBridgeApplyAction = pending.createdBridge ? .delete : .revert
        let nic = LinuxHostBridgeApply.readOwnerMarker(bridge: pending.target)?.uplink
            ?? pending.target
        let request = LinuxHostBridgeApplyRequest(
            action: action,
            bridge: workloadBridgeName(pending),
            nic: nic,
            confirm: true,
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
