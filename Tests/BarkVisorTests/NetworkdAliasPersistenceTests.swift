import Foundation
import Testing
@testable import BarkVisorCore

struct NetworkdAliasPersistenceTests {
    @Test func `runtime netplan unit wins over a later alias file`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = root.appendingPathComponent("run")
        let etc = root.appendingPathComponent("etc")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        try "[Match]\nName=eth0\n[Network]\nDHCP=yes\n".write(
            to: run.appendingPathComponent("10-netplan-eth0.network"), atomically: true, encoding: .utf8,
        )
        let files = LinuxHostAddressPersist.persistFiles(
            interface: "eth0", cidrs: ["192.0.2.20/24"], backend: .systemdNetworkd,
            directories: LinuxHostAddressPersist.networkdSearchDirectories(
                etc: etc.path,
                run: run.path,
                lib: root.appendingPathComponent("missing").path,
            ),
        )
        #expect(files.count == 1)
        #expect(files[0].path == run.appendingPathComponent("10-netplan-eth0.network.d/90-barkvisor-aliases.conf").path)
        #expect(!files[0].path.contains("90-barkvisor-eth0-aliases.network"))
    }

    @Test func `vendor wildcard does not beat a local exact unit`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let etc = root.appendingPathComponent("etc")
        let lib = root.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try "[Match]\nName=en*\n[Network]\nDHCP=yes\n".write(
            to: lib.appendingPathComponent("99-default.network"), atomically: true, encoding: .utf8,
        )
        try "[Match]\nName=enp1s0\n[Network]\nDHCP=yes\n".write(
            to: etc.appendingPathComponent("20-enp1s0.network"), atomically: true, encoding: .utf8,
        )
        let match = LinuxHostAddressPersist.networkdMatchingNetworkFile(
            interface: "enp1s0",
            directories: LinuxHostAddressPersist.networkdSearchDirectories(
                etc: etc.path,
                run: root.appendingPathComponent("missing").path,
                lib: lib.path,
            ),
        )
        #expect(match == etc.appendingPathComponent("20-enp1s0.network").path)
    }
}
