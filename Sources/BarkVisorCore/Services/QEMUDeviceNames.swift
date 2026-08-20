import Foundation

/// QEMU `-drive` / QMP device ids. Builder and live disk ops must share these.
public enum QEMUDeviceNames {
    public static let bootDrive = "boot0"

    public static func extraDrive(_ index: Int) -> String {
        "extra\(index)"
    }

    public static func cdromDrive(_ index: Int) -> String {
        "cdrom\(index)"
    }

    /// QMP `block_resize` target — same `id=` QEMUBuilder puts on `-drive`.
    public static func blockDevice(
        diskId: String,
        bootDiskId: String,
        additionalDiskIds: [String],
    ) throws -> String {
        if diskId == bootDiskId { return bootDrive }
        if let idx = additionalDiskIds.firstIndex(of: diskId) {
            return extraDrive(idx)
        }
        throw BarkVisorError.diskCreateFailed(
            "Disk \(diskId) is not attached as boot or additional disk",
        )
    }
}
