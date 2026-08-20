import Foundation
import GRDB

/// Stateless service for QMP disk operations on running VMs.
public struct QMPDiskService: Sendable {
    public let vmManager: VMManager
    public let dbPool: DatabasePool

    /// Online resize a disk attached to a running VM via QMP block_resize
    public func resizeDisk(vmID: String, disk: Disk, sizeBytes: Int64) async throws {
        guard disk.vmId == vmID else {
            throw BarkVisorError.diskCreateFailed("Disk \(disk.id) is not attached to VM \(vmID)")
        }

        guard let socketPath = await vmManager.qmpSocketPath(for: vmID) else {
            throw BarkVisorError.vmNotRunning(vmID)
        }

        let vm = try await dbPool.read { db in try VM.fetchOne(db, key: vmID) }
        guard let vm else {
            throw BarkVisorError.diskCreateFailed(
                "Disk \(disk.id) is not attached as boot or additional disk",
            )
        }
        let deviceName = try QEMUDeviceNames.blockDevice(
            diskId: disk.id,
            bootDiskId: vm.bootDiskId,
            additionalDiskIds: vm.decodedAdditionalDiskIds,
        )

        let client = QMPClient(socketPath: socketPath)
        try client.connect()
        defer { client.disconnect() }

        _ = try client.executeWithArgs(
            "block_resize",
            args: [
                "device": deviceName,
                "size": sizeBytes,
            ],
        )
    }

    public init(vmManager: VMManager, dbPool: DatabasePool) {
        self.vmManager = vmManager
        self.dbPool = dbPool
    }
}
