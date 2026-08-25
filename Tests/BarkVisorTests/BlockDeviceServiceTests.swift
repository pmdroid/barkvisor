import Foundation
import Testing
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
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

    @Test func `host use reason rejects root mounted and swap devices`() {
        let mounts = """
        /dev/nvme0n1p2 / ext4 rw 0 0
        /dev/sdb1 /mnt/data ext4 rw 0 0
        """
        let swaps = """
        Filename Type Size Used Priority
        /dev/sdc1 partition 1 0 -2
        """
        #expect(BlockDeviceService.hostUseReason(path: "/dev/nvme0n1", mounts: mounts) == "Host root disk")
        #expect(BlockDeviceService.hostUseReason(path: "/dev/nvme0n1p2", mounts: mounts) == "Host root disk")
        #expect(BlockDeviceService.hostUseReason(path: "/dev/sdb1", mounts: mounts) == "Device is mounted on the host")
        #expect(BlockDeviceService.hostUseReason(path: "/dev/sdb", mounts: mounts) == "Device is in use by the host")
        #expect(BlockDeviceService.hostUseReason(path: "/dev/sdc", mounts: mounts, swaps: swaps) == "Device is in use by the host")
        #expect(BlockDeviceService.hostUseReason(path: "/dev/sdd", mounts: mounts, swaps: swaps) == nil)
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
        #expect(sda.sizeBytes == 1_953_525_168 * 512)
        #expect(sda.model == "Samsung SSD")
        #expect(!sda.attachable)
        #expect(sda.excludedReason == "Host root disk")
        let sdb = try #require(devices.first { $0.name == "sdb" })
        #expect(sdb.attachable)
        #expect(devices.contains { $0.name == "loop0" } == false)

        let mounted = BlockDeviceService.listSysfsDevices(
            root: root,
            mounts: "/dev/sda2 / ext4 rw 0 0\n/dev/sdb1 /mnt/data ext4 rw 0 0\n",
        )
        let mountedSdb = try #require(mounted.first { $0.name == "sdb" })
        #expect(!mountedSdb.attachable)
        #expect(mountedSdb.excludedReason == "Device is in use by the host")
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

    @Test func `readWriteDeniedReason is nil when the probe opens`() {
        #expect(
            BlockDeviceService.readWriteDeniedReason(path: "/dev/sdb", openReadWrite: { _ in })
                == nil,
        )
    }

    @Test func `readWriteDeniedReason names the path and disk group on EACCES`() {
        let reason = BlockDeviceService.readWriteDeniedReason(
            path: "/dev/sda",
            openReadWrite: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            },
        )
        #expect(reason == BlockDeviceService.readWriteDeniedCopy(path: "/dev/sda"))
        #expect(reason?.contains("/dev/sda") == true)
        #expect(reason?.contains("disk group") == true)
        #expect(reason?.contains("udev ACL") == true)
    }

    @Test func `requireReadWrite throws badRequest on EPERM`() {
        do {
            try BlockDeviceService.requireReadWrite(
                path: "/dev/sda",
                openReadWrite: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
                },
            )
            Issue.record("expected requireReadWrite to throw")
        } catch let BarkVisorError.badRequest(msg) {
            #expect(msg == BlockDeviceService.readWriteDeniedCopy(path: "/dev/sda"))
        } catch {
            Issue.record("expected badRequest, got \(error)")
        }
    }

    @Test func `requireHostDeviceReadWrite skips image paths`() throws {
        try BlockDeviceService.requireHostDeviceReadWrite(
            paths: ["/var/lib/barkvisor/disks/a.qcow2"],
            openReadWrite: { _ in Issue.record("must not open image paths") },
        )
    }

    @Test func `additionalDiskArgs fails closed before the drive line on permission`() {
        let disk = Disk(
            id: "d1",
            name: "passthrough",
            path: "/dev/sda",
            sizeBytes: 1_024,
            format: "raw",
            vmId: "vm-1",
            autoCreated: false,
            status: "ready",
            createdAt: "2026-01-01T00:00:00Z",
        )
        do {
            _ = try QEMUBuilder.additionalDiskArgs(
                [disk],
                openReadWrite: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                },
            )
            Issue.record("expected additionalDiskArgs to throw")
        } catch let BarkVisorError.badRequest(msg) {
            #expect(msg == BlockDeviceService.readWriteDeniedCopy(path: "/dev/sda"))
            #expect(!msg.contains("-drive"))
            #expect(!msg.contains("qemu"))
        } catch {
            Issue.record("expected badRequest, got \(error)")
        }
    }

    @Test func `additionalDiskArgs still emits drive when probe ok`() throws {
        let disk = Disk(
            id: "d1",
            name: "passthrough",
            path: "/dev/sdb",
            sizeBytes: 1_024,
            format: "raw",
            vmId: "vm-1",
            autoCreated: false,
            status: "ready",
            createdAt: "2026-01-01T00:00:00Z",
        )
        let args = try QEMUBuilder.additionalDiskArgs([disk], openReadWrite: { _ in })
        #expect(args.contains("-drive"))
        #expect(args.contains { $0.contains("file=/dev/sdb") })
    }
}
