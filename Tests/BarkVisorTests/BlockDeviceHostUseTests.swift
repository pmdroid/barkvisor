import Foundation
import Testing
@testable import BarkVisorCore

struct BlockDeviceHostUseTests {
    @Test func `partition backing active mapper is excluded`() throws {
        try withDevices(["sda", "sdb", "dm-0"]) { root in
            try addDirectory("sda/sda2/holders/dm-0", root: root)
            try addDirectory("dm-0/dm", root: root)
            try "ubuntu--vg-ubuntu--lv\n".write(to: root.appendingPathComponent("dm-0/dm/name"), atomically: true, encoding: .utf8)
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
            let devices = BlockDeviceService.listSysfsDevices(root: root, swaps: "/dev/dm-0\tpartition\t1024\t0\t-2\n")
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
            #expect(devices.map(\.attachable) == [true, true])
        }
    }

    @Test func `imported ZFS pool members and spares are excluded`() throws {
        try withDevices(["sda", "sdb", "sdc", "sdd"]) { root in
            try addDirectory("sdb/sdb1/holders", root: root)
            let status = """
              pool: tank
            config:
            \tNAME STATE READ WRITE CKSUM
            \ttank ONLINE 0 0 0
            \t  /dev/sdb1 ONLINE 0 0 0
            \tlogs
            \t  /dev/sdc ONLINE 0 0 0
            \tspares
            \t  /dev/sdd AVAIL
            """
            let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: "tank/data /data zfs rw 0 0\n", zpoolStatus: status)
            #expect(devices.first { $0.name == "sda" }?.attachable == true)
            for name in ["sdb", "sdc", "sdd"] {
                #expect(devices.first { $0.name == name }?.attachable == false)
            }
        }
    }

    @Test func `unknown pool membership excludes devices`() throws {
        try withDevices(["sda", "sdb"]) { root in
            let devices = BlockDeviceService.listSysfsDevices(root: root, zpoolStatus: nil)
            #expect(devices.map(\.attachable) == [false, false])
        }
    }

    @Test func `ZFS discovery is read only and uses real full vdev paths`() {
        let status = "pool: tank\n\t/dev/sdb1 ONLINE 0 0 0\n"
        let result = BlockDeviceService.readZpoolStatus(
            mounts: "tank/data /data zfs rw 0 0\n", executablePath: "/fixture/zpool", zfsLoaded: true,
            invoke: { path, args in
                #expect(path == "/fixture/zpool")
                #expect(args == ["status", "-LP"])
                return CommandResult(exitCode: 0, stdout: Data(status.utf8), stderr: Data())
            },
        )
        #expect(result == status)
    }

    @Test func `successful zero pool discovery preserves unused devices`() throws {
        let status = BlockDeviceService.readZpoolStatus(
            mounts: "", executablePath: "/fixture/zpool", zfsLoaded: true,
            invoke: { _, _ in CommandResult(exitCode: 0, stdout: Data(), stderr: Data("no pools available\n".utf8)) },
        )
        #expect(status == "")
        try withDevices(["sda"]) { root in
            #expect(BlockDeviceService.listSysfsDevices(root: root, zpoolStatus: status).first?.attachable == true)
        }
    }

    @Test func `installed ZFS tooling without loaded module preserves unused devices`() {
        let status = BlockDeviceService.readZpoolStatus(
            mounts: "", executablePath: "/fixture/zpool", zfsLoaded: false,
            invoke: { _, _ in
                Issue.record("must not load ZFS to inspect unused disks")
                return CommandResult(exitCode: 1, stdout: Data(), stderr: Data())
            },
        )
        #expect(status == "")
    }

    @Test func `failed or empty ZFS discovery remains unknown`() {
        for code: Int32 in [0, 1] {
            let status = BlockDeviceService.readZpoolStatus(
                mounts: "tank/data /data zfs rw 0 0\n", executablePath: "/fixture/zpool", zfsLoaded: true,
                invoke: { _, _ in CommandResult(exitCode: code, stdout: Data(), stderr: Data()) },
            )
            #expect(status == nil)
        }
    }

    @Test func `mounted ZFS cannot be cleared by zero pool report`() {
        let status = BlockDeviceService.readZpoolStatus(
            mounts: "tank/data /data zfs rw 0 0\n", executablePath: "/fixture/zpool", zfsLoaded: false,
            invoke: { _, _ in CommandResult(exitCode: 0, stdout: Data(), stderr: Data("no pools available\n".utf8)) },
        )
        #expect(status == nil)
    }

    @Test func `layer device partition names preserve whole identity`() {
        #expect(BlockDeviceService.wholeDiskName(from: "md0") == "md0")
        #expect(BlockDeviceService.wholeDiskName(from: "dm-0") == "dm-0")
        #expect(BlockDeviceService.wholeDiskName(from: "md0p1") == "md0")
        #expect(BlockDeviceService.wholeDiskName(from: "dm-0p1") == "dm-0")
        #expect(BlockDeviceService.hostUseReason(path: "/dev/md0", mounts: "/dev/md0p1 /data ext4 rw 0 0\n") != nil)
        #expect(BlockDeviceService.hostUseReason(path: "/dev/dm-0", mounts: "/dev/dm-0p1 /data ext4 rw 0 0\n") != nil)
    }

    @Test func `fresh start rejects a newly used device before opening it`() {
        do {
            try BlockDeviceService.requireHostDeviceReadWrite(
                paths: ["/dev/sdb"],
                openReadWrite: { _ in Issue.record("must reject host use before RW probe") },
                hostUse: { _ in "Device is in use by the host" },
            )
            Issue.record("expected host use rejection")
        } catch let BarkVisorError.badRequest(reason) {
            #expect(reason == "Device is in use by the host")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `mounted raid partition excludes underlying physical disk`() throws {
        try withDevices(["sda", "sdb", "md0"]) { root in
            try addDirectory("md0/slaves/sdb", root: root)
            try addDirectory("md0/md0p1/holders", root: root)
            let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: "/dev/md0p1 /data ext4 rw 0 0\n")
            #expect(devices.first { $0.name == "sdb" }?.attachable == false)
            #expect(devices.first { $0.name == "sda" }?.attachable == true)
        }
    }

    @Test func `unreadable sysfs holder evidence excludes device`() throws {
        try withDevices(["sda"]) { root in
            let holders = root.appendingPathComponent("sda/holders")
            try FileManager.default.removeItem(at: holders)
            try "invalid sysfs evidence".write(to: holders, atomically: true, encoding: .utf8)
            #expect(BlockDeviceService.listSysfsDevices(root: root).first?.attachable == false)
        }
    }

    @Test func `malformed successful pool discovery remains unknown`() {
        let status = BlockDeviceService.readZpoolStatus(
            mounts: "", executablePath: "/fixture/zpool", zfsLoaded: true,
            invoke: { _, _ in CommandResult(exitCode: 0, stdout: Data("unexpected response".utf8), stderr: Data()) },
        )
        #expect(status == nil)
    }

    @Test func `sd disk names ending in p keep their partition holders`() throws {
        #expect(BlockDeviceService.wholeDiskName(from: "sdp1") == "sdp")
        try withDevices(["sdp", "sdb", "dm-0"]) { root in
            try addDirectory("sdp/sdp1/holders/dm-0", root: root)
            let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: "/dev/dm-0 /data ext4 rw 0 0\n")
            #expect(devices.first { $0.name == "sdp" }?.attachable == false)
            #expect(devices.first { $0.name == "sdb" }?.attachable == true)
        }
    }

    @Test func `unresolved imported ZFS member protects all candidate disks`() throws {
        try withDevices(["sda", "sdb"]) { root in
            let status = "pool: tank\n/dev/disk/by-id/sdb ONLINE 0 0 0\n"
            let devices = BlockDeviceService.listSysfsDevices(root: root, zpoolStatus: status)
            #expect(devices.map(\.attachable) == [false, false])
        }
    }

    @Test func `missing member dependency directory remains unknown`() throws {
        try withDevices(["sda", "sdb"]) { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("sdb/slaves"))
            let devices = BlockDeviceService.listSysfsDevices(root: root, mounts: "/dev/sdb /data ext4 rw 0 0\n")
            #expect(devices.first { $0.name == "sda" }?.attachable == false)
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
