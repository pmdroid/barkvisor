import Foundation
import Testing
@testable import BarkVisorCore

@Suite("DiskService clone partition-table verification", .serialized)
struct DiskServiceCloneVerifyTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "disk-clone-verify-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func qemuImg() -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("qemu-img")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func makeRaw(dir: URL, name: String, mutate: (inout [UInt8]) -> Void) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 64 * 1_048_576)
        mutate(&bytes)
        let path = dir.appendingPathComponent(name)
        try Data(bytes).write(to: path)
        return path.path
    }

    @Test func `clone keeps a GPT cloud image bootable`() throws {
        guard qemuImg() != nil else { return }
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeRaw(dir: dir, name: "gpt.raw") { bytes in
            bytes.replaceSubrange(512 ..< 520, with: Array("EFI PART".utf8))
            bytes[510] = 0x55
            bytes[511] = 0xAA
        }
        try DiskService.cloneAndResize(
            sourcePath: source,
            destPath: dir.appendingPathComponent("gpt.qcow2"),
            sizeGB: nil,
        )
    }

    @Test func `clone rejects a disk with no partition table`() async throws {
        guard qemuImg() != nil else { return }
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeRaw(dir: dir, name: "empty.raw") { _ in }
        await #expect(throws: BarkVisorError.self) {
            try DiskService.cloneAndResize(
                sourcePath: source,
                destPath: dir.appendingPathComponent("empty.qcow2"),
                sizeGB: nil,
            )
        }
    }

    @Test func `clone accepts an MBR image`() throws {
        guard qemuImg() != nil else { return }
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeRaw(dir: dir, name: "mbr.raw") { bytes in
            bytes[510] = 0x55
            bytes[511] = 0xAA
        }
        try DiskService.cloneAndResize(
            sourcePath: source,
            destPath: dir.appendingPathComponent("mbr.qcow2"),
            sizeGB: nil,
        )
    }
}
