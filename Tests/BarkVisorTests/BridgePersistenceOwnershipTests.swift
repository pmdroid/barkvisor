import Foundation
import Testing
@testable import BarkVisorCore

struct BridgePersistenceOwnershipTests {
    @Test func `untagged matching administrator files do not establish ownership`() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("[NetDev]\nName=br0\nKind=bridge\n", name: "10-admin-br0.netdev", dir: dir)
        try write("[Match]\nName=br0\n[Network]\nDHCP=yes\n", name: "20-admin-br0.network", dir: dir)
        try write("[Match]\nName=eth0\n[Network]\nBridge=br0\n", name: "20-admin-eth0.network", dir: dir)
        let persistence = LinuxHostBridgeApply.systemdBridgePersist(bridge: "br0", dir: dir.path)
        let leftover = LinuxHostBridgeApply.leftoverHostBridge(bridge: "br0", dir: dir.path)
        let ownership = LinuxHostBridgeApply.ownership(bridge: "br0", marker: nil, acl: nil, leftoverPersist: leftover)
        #expect(persistence.remove.isEmpty)
        #expect(persistence.rewrite.isEmpty)
        #expect(!ownership.owned)
        #expect(!ownership.createdBridge)
        let writer = RecordingLinuxHostBridgeMutator()
        let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            bridges: [HostBridgeSnapshot(name: "br0", enslaved: ["eth0"])],
            defaultRouteInterface: "eth0",
        ))
        let probe = LinuxHostBridgeApplyProbe(
            facts: facts, backend: .systemdNetworkd,
            owned: ownership.owned, createdBridge: ownership.createdBridge,
            existingInterfaces: ["br0", "eth0"],
        )
        let result = try LinuxHostBridgeApplyLive.run(
            request: LinuxHostBridgeApplyRequest(action: .delete, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe, mutator: writer,
        )
        #expect(result.refused)
        #expect(writer.steps.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
    }

    @Test func `owned persistence cleanup excludes foreign files on the same bridge`() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let netdev = "[NetDev]\nName=br0\nKind=bridge\n"
        let port = "[Match]\nName=eth0\n[Network]\nBridge=br0\n"
        try write(netdev, name: "10-admin-br0.netdev", dir: dir)
        try write(port, name: "20-admin-eth0.network", dir: dir)
        try write("# managed-by: barkvisor\n" + netdev, name: "90-barkvisor-br0.netdev", dir: dir)
        try write("# managed-by: barkvisor\n" + port, name: "90-barkvisor-eth0.network", dir: dir)
        let persistence = LinuxHostBridgeApply.systemdBridgePersist(bridge: "br0", dir: dir.path)
        #expect(persistence.remove.map { URL(fileURLWithPath: $0).lastPathComponent } == ["90-barkvisor-br0.netdev"])
        #expect(persistence.rewrite.map { URL(fileURLWithPath: $0).lastPathComponent } == ["90-barkvisor-eth0.network"])
        #expect(LinuxHostBridgeApply.leftoverHostBridge(bridge: "br0", dir: dir.path))
    }

    @Test func `ACL permission alone does not prove BarkVisor created a bridge`() {
        let ownership = LinuxHostBridgeApply.ownership(
            bridge: "br0", marker: nil, acl: "# barkvisor:allow-br0\nallow br0\n",
        )
        #expect(ownership.owned)
        #expect(!ownership.createdBridge)
    }

    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ body: String, name: String, dir: URL) throws {
        try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
