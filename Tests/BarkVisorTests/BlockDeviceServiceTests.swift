import Foundation
import Testing
@testable import BarkVisorCore

struct BlockDeviceServiceTests {
    @Test func `skips loop ram and mapper names`() {
        #expect(BlockDeviceService.shouldSkip("loop0"))
        #expect(BlockDeviceService.shouldSkip("ram1"))
        #expect(BlockDeviceService.shouldSkip("zram0"))
        #expect(BlockDeviceService.shouldSkip("sr0"))
        #expect(BlockDeviceService.shouldSkip("nbd0"))
        #expect(BlockDeviceService.shouldSkip("dm-0"))
        #expect(BlockDeviceService.shouldSkip("md0"))
        #expect(!BlockDeviceService.shouldSkip("sda"))
        #expect(!BlockDeviceService.shouldSkip("nvme0n1"))
        #expect(!BlockDeviceService.shouldSkip("sdb"))
    }

    @Test func `whole disk name strips partitions`() {
        #expect(BlockDeviceService.wholeDiskName(from: "sda1") == "sda")
        #expect(BlockDeviceService.wholeDiskName(from: "nvme0n1p2") == "nvme0n1")
        #expect(BlockDeviceService.wholeDiskName(from: "mmcblk0p1") == "mmcblk0")
        #expect(BlockDeviceService.wholeDiskName(from: "sdb") == "sdb")
        #expect(BlockDeviceService.wholeDiskName(from: "nvme0n1") == "nvme0n1")
    }

    @Test func `root disk is detected from mounts`() {
        let mounts = """
        /dev/nvme0n1p2 / ext4 rw 0 0
        /dev/sdb1 /mnt/data ext4 rw 0 0
        """
        #expect(BlockDeviceService.rootDiskName(from: mounts) == "nvme0n1")
    }

    @Test func `sysfs listing skips loop and marks the root disk`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func addDisk(_ name: String, sectors: String, model: String) throws {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try sectors.write(
                to: dir.appendingPathComponent("size"), atomically: true, encoding: .utf8,
            )
            let device = dir.appendingPathComponent("device")
            try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
            try model.write(
                to: device.appendingPathComponent("model"), atomically: true, encoding: .utf8,
            )
        }
        try addDisk("sda", sectors: "1953525168", model: "Samsung SSD")
        try addDisk("sdb", sectors: "976773168", model: "WD Disk")
        try addDisk("loop0", sectors: "0", model: "loop")

        let mounts = "/dev/sda2 / ext4 rw 0 0\n"
        let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: mounts)
        #expect(devices.count == 2)
        let sda = try #require(devices.first { $0.name == "sda" })
        #expect(sda.path == "/dev/sda")
        #expect(sda.sizeBytes == 1953525168 * 512)
        #expect(sda.model == "Samsung SSD")
        #expect(!sda.attachable)
        #expect(sda.excludedReason == "Host root disk")
        let sdb = try #require(devices.first { $0.name == "sdb" })
        #expect(sdb.attachable)
        #expect(devices.contains { $0.name == "loop0" } == false)
    }

    @Test func `listDevices is empty on macOS`() {
        #if os(macOS)
            #expect(BlockDeviceService.listDevices().isEmpty)
        #endif
    }

    @Test func `qemu cache is none for host devices`() {
        #expect(QEMUBuilder.diskCacheMode(path: "/dev/sdb") == "none")
        #expect(QEMUBuilder.diskCacheMode(path: "/var/lib/barkvisor/disks/a.qcow2") == "writeback")
    }
}
