import Foundation
import GRDB

public protocol QMPDiskResizing: Sendable {
    func resize(vmID: String, disk: Disk, device: String, sizeBytes: Int64) async throws
}

public struct LiveQMPDiskResizer: QMPDiskResizing {
    public let vmManager: VMManager

    public init(vmManager: VMManager) {
        self.vmManager = vmManager
    }

    public func resize(vmID: String, disk: Disk, device: String, sizeBytes: Int64) async throws {
        guard let socketPath = await vmManager.qmpSocketPath(for: vmID) else {
            throw BarkVisorError.vmNotRunning(vmID)
        }
        let client = QMPClient(socketPath: socketPath)
        try client.connect()
        defer { client.disconnect() }
        _ = try client.executeWithArgs(
            "block_resize",
            args: [
                "device": device,
                "size": sizeBytes,
            ],
        )
    }
}

public struct QMPDiskService: Sendable {
    public let vmManager: VMManager
    public let dbPool: DatabasePool
    private let resizer: any QMPDiskResizing

    public func resizeDisk(vmID: String, disk: Disk, sizeBytes: Int64) async throws {
        let vm = try await dbPool.read { db in try VM.fetchOne(db, key: vmID) }
        guard let vm else {
            throw BarkVisorError.diskCreateFailed(
                "Disk \(disk.id) is not attached as boot or additional disk",
            )
        }
        let attached = vm.bootDiskId == disk.id || vm.decodedAdditionalDiskIds.contains(disk.id)
        guard attached else {
            throw BarkVisorError.diskCreateFailed("Disk \(disk.id) is not attached to VM \(vmID)")
        }
        let device = try QEMUDeviceNames.blockDevice(
            diskId: disk.id,
            bootDiskId: vm.bootDiskId ?? "",
            additionalDiskIds: vm.decodedAdditionalDiskIds,
        )
        try await resizer.resize(vmID: vmID, disk: disk, device: device, sizeBytes: sizeBytes)
    }

    public init(vmManager: VMManager, dbPool: DatabasePool, resizer: (any QMPDiskResizing)? = nil) {
        self.vmManager = vmManager
        self.dbPool = dbPool
        self.resizer = resizer ?? LiveQMPDiskResizer(vmManager: vmManager)
    }
}
