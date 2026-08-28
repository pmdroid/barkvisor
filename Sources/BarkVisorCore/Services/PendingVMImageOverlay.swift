import Foundation
import GRDB

public struct PendingVMImageOverlay: Sendable, Equatable {
    public var pendingImageId: String
    public var downloadPercent: Int?

    public init(pendingImageId: String, downloadPercent: Int?) {
        self.pendingImageId = pendingImageId
        self.downloadPercent = downloadPercent
    }

    public static func load(
        db: Database,
        vmIDs: [String]?,
        lastProgress: [String: ImageProgressEvent],
    ) throws -> [String: PendingVMImageOverlay] {
        let pending: [PendingDeploy]
        if let vmIDs {
            if vmIDs.isEmpty { return [:] }
            pending = try PendingDeploy.filter(vmIDs.contains(PendingDeploy.Columns.vmId)).fetchAll(db)
        } else {
            pending = try PendingDeploy.fetchAll(db)
        }
        if pending.isEmpty { return [:] }
        let imageIDs = Array(Set(pending.map(\.imageId)))
        let images = try VMImage.fetchAll(db, keys: imageIDs)
        let byID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        var out: [String: PendingVMImageOverlay] = [:]
        out.reserveCapacity(pending.count)
        for row in pending {
            let status = byID[row.imageId]?.status
            out[row.vmId] = PendingVMImageOverlay(
                pendingImageId: row.imageId,
                downloadPercent: ImageTransferPercent.current(
                    status: status,
                    lastProgress: lastProgress[row.imageId],
                ),
            )
        }
        return out
    }
}

public actor PendingVMProgressTicker {
    private var lastSent: [String: PendingVMImageOverlay] = [:]

    public init() {}

    public func tick(
        db: DatabasePool,
        downloader: ImageDownloader,
        stream: VMStateStreamService,
    ) async {
        do {
            let pending = try await db.read { db in try PendingDeploy.fetchAll(db) }
            let lastProgress = await downloader.lastProgress(imageIDs: pending.map(\.imageId))
            let overlays = try await db.read { db in
                try PendingVMImageOverlay.load(db: db, vmIDs: nil, lastProgress: lastProgress)
            }
            let watchIDs = Array(Set(overlays.keys).union(lastSent.keys))
            let states: [String: String] = try await db.read { db in
                let vms = try VM.fetchAll(db, keys: watchIDs)
                return Dictionary(uniqueKeysWithValues: vms.map { ($0.id, $0.state) })
            }
            for (vmID, overlay) in overlays {
                if lastSent[vmID] == overlay { continue }
                lastSent[vmID] = overlay
                await stream.broadcast(
                    event: VMStateEvent(
                        id: vmID,
                        state: states[vmID] ?? "provisioning",
                        error: nil,
                        pendingImageId: overlay.pendingImageId,
                        downloadPercent: overlay.downloadPercent,
                    ),
                )
            }
            for vmID in lastSent.keys where overlays[vmID] == nil {
                lastSent.removeValue(forKey: vmID)
                await stream.broadcast(
                    event: VMStateEvent(
                        id: vmID,
                        state: states[vmID] ?? "stopped",
                        error: nil,
                        pendingImageId: nil,
                        downloadPercent: nil,
                    ),
                )
            }
        } catch {}
    }
}
