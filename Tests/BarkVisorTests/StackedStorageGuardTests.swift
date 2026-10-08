import Foundation
import Testing
@testable import BarkVisorCore

struct StackedStorageGuardTests {
    @Test func `physical member of a mounted mapper holder is rejected`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sdb/holders"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dm-0/dm"), withIntermediateDirectories: true)
        try "vg-root\n".write(to: root.appendingPathComponent("dm-0/dm/name"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sdb/holders/dm-0"), withIntermediateDirectories: true)
        let reason = BlockDeviceService.hostUseReason(
            path: "/dev/sdb", mounts: "/dev/mapper/vg-root / ext4 rw 0 0\n", swaps: "",
            sysfsRoot: root,
        )
        #expect(reason == "Device backs host storage")
    }
}
