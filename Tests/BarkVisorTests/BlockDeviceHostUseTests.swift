import Foundation
import Testing
@testable import BarkVisorCore

struct BlockDeviceHostUseTests {
    @Test func `partition backing active mapper is excluded`() throws {
        try withDevices(["sda", "sdb", "dm-0"]) { root in
            try addDirectory("sda/sda2/holders/dm-0", root: root)
            let devices = BlockDeviceService.listSysfsDevices(
                root: root, mounts: "/dev/mapper/ubuntu--vg-ubuntu--lv / ext4 rw 0 0\n",
            )
            #expect(devices.first { $0.name == "sda" }?.attachable == false)
            #expect(devices.first { $0.name == "sdb" }?.attachable == true)
        }
    }

    @Test func `whole disk backing active raid is excluded`() throws {
        try withDevices(["sda", "sdb", "md0"]) { root in
            try addDirectory("sdb/holders/md0", root: root)
            let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: "/dev/md0 /data ext4 rw 0 0\n")
            #expect(devices.first { $0.name == "sdb" }?.attachable == false)
            #expect(devices.first { $0.name == "sda" }?.attachable == true)
        }
    }

    @Test func `mounted raid dependencies exclude backing disk`() throws {
        try withDevices(["sda", "sdb", "md0", "dm-0"]) { root in
            try addDirectory("md0/slaves/dm-0", root: root)
            try addDirectory("dm-0/slaves/sdb2", root: root)
            try addDirectory("sdb/sdb2/holders", root: root)
            let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: "/dev/md0 /data ext4 rw 0 0\n")
            #expect(devices.first { $0.name == "sdb" }?.attachable == false)
            #expect(devices.first { $0.name == "sda" }?.attachable == true)
        }
    }

    @Test func `mapped swap dependencies exclude backing disk`() throws {
        try withDevices(["sda", "sdb", "dm-0"]) { root in
            try addDirectory("dm-0/slaves/sdb1", root: root)
            try addDirectory("sdb/sdb1/holders", root: root)
            let devices = BlockDeviceService.listSysfsDevices(root: root, swaps: "/dev/dm-0 partition 1024 0 -2\n")
            #expect(devices.first { $0.name == "sdb" }?.attachable == false)
            #expect(devices.first { $0.name == "sda" }?.attachable == true)
        }
    }

    @Test func `unused partitioned disks remain attachable`() throws {
        try withDevices(["sda", "nvme0n1"]) { root in
            try addDirectory("sda/sda1/holders", root: root)
            try addDirectory("nvme0n1/nvme0n1p1/holders", root: root)
            let devices = BlockDeviceService.listSysfsDevices(root: root)
            #expect(devices.count == 2)
            #expect(devices.allSatisfy { $0.attachable })
        }
    }

    private func withDevices(_ names: [String], body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("block-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in names {
            try addDirectory("\(name)/holders", root: root)
            try addDirectory("\(name)/slaves", root: root)
            try "1024\n".write(to: root.appendingPathComponent("\(name)/size"), atomically: true, encoding: .utf8)
        }
        try body(root)
    }

    private func addDirectory(_ path: String, root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
}
