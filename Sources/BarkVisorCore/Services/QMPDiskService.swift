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

        // Determine the QMP device name for this disk
        let deviceName: String
        let vm = try await dbPool.read { db in try VM.fetchOne(db, key: vmID) }
        if let vm, vm.bootDiskId == disk.id {
            deviceName = "boot0"
        } else if let vm, let json = vm.additionalDiskIds, let data = json.data(using: .utf8) {
            let ids = try JSONDecoder().decode([String].self, from: data)
            if let idx = ids.firstIndex(of: disk.id) {
                deviceName = "extra\(idx)"
            } else {
                throw BarkVisorError.diskCreateFailed("Disk \(disk.id) is not in VM's additional disks")
            }
        } else {
            throw BarkVisorError.diskCreateFailed(
                "Disk \(disk.id) is not attached as boot or additional disk",
            )
        }

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
