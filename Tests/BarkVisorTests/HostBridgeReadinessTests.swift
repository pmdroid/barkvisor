import Foundation
import Testing
@testable import BarkVisorCore

private struct StubHostBridgeFacts: HostBridgeFactSource {
    var helperPath: String? = "/usr/lib/qemu/qemu-bridge-helper"
    var helperSetuid = false
    var aclAllowsSuggested: Bool? = false
    var bridges: [HostBridgeSnapshot] = []
    var defaultRouteInterface: String? = "eth0"

    func inputs() -> HostBridgeFactInputs {
        HostBridgeFactInputs(
            helperPath: helperPath,
            helperSetuid: helperSetuid,
            aclAllowsSuggested: aclAllowsSuggested,
            bridges: bridges,
            defaultRouteInterface: defaultRouteInterface,
        )
    }
}

struct HostBridgeReadinessTests {
    @Test func `default route parser reads iface with dest 00000000`() {
        let table = """
        Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
        eth0	00000000	010011AC	0003	0	0	100	00000000	0	0	0
        eth0	000011AC	00000000	0001	0	0	100	0000FFFF	0	0	0
        """
        #expect(LinuxHostNetwork.defaultRouteInterface(routeTable: table) == "eth0")
    }

    @Test func `acl parser allow br0`() {
        #expect(LinuxHostNetwork.bridgeACLAllows("br0", fileContents: "allow br0\n"))
        #expect(LinuxHostNetwork.bridgeACLAllows("br0", fileContents: "allow all\n"))
        #expect(!LinuxHostNetwork.bridgeACLAllows("br0", fileContents: "allow br1\n"))
    }

    @Test func `probe never reports ready on macOS`() {
        #if os(macOS)
            let ready = HostBridgeReadinessService.probe()
            #expect(!ready.ready)
            #expect(ready.bridges.isEmpty)
        #endif
    }

    @Test func `facts seam is ready only with helper ACL and a bridge`() {
        var stub = StubHostBridgeFacts()
        let missing = HostBridgeFactsService.probe(source: stub)
        #expect(!missing.ready)
        #expect(missing.remediations.map(\.id) == ["create-bridge", "allow-acl", "setuid-helper"])
        #expect(missing.suggestedBridge == HostBridgeFactsService.suggestedBridgeName)

        stub.helperSetuid = true
        stub.aclAllowsSuggested = true
        stub.bridges = [HostBridgeSnapshot(name: "br0", enslaved: ["enp2s0"])]
        let ready = HostBridgeFactsService.probe(source: stub)
        #expect(ready.ready)
        #expect(ready.remediations.isEmpty)
        #expect(ready.onlyUplink == false)
    }

    @Test func `only uplink when default route is not enslaved and no bridge`() {
        var stub = StubHostBridgeFacts()
        stub.defaultRouteInterface = "eth0"
        let facts = HostBridgeFactsService.probe(source: stub)
        #expect(facts.onlyUplink)
        #expect(!facts.ready)
    }

    @Test func `linux host-bridge infos never forge plist or daemon`() {
        let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            helperPath: HostBridgeFactsService.qemuBridgeHelperCandidates[0],
            helperSetuid: true,
            aclAllowsSuggested: true,
            bridges: [HostBridgeSnapshot(name: "br0", enslaved: ["eth1"])],
            defaultRouteInterface: "eth1",
        ))
        let rows = HostBridgeFactsService.hostBridgeInfos(from: facts)
        #expect(rows.count == 1)
        #expect(rows[0].interface == "br0")
        #expect(rows[0].status == "active")
        #expect(rows[0].plistExists == false)
        #expect(rows[0].daemonRunning == false)
        #expect(rows[0].socketPath == nil)
    }

    @Test func `linux privilege list does not mint macOS-shaped rows`() async throws {
        let states = try await LinuxPrivilegeService().getAllBridgeStates()
        #expect(states.isEmpty)
        for state in states {
            #expect(!state.plistExists)
            #expect(!state.daemonRunning)
        }
    }

    @Test func `status map on Linux uses facts not fabricated records`() {
        #if os(Linux)
            let fromDB = HostBridgeFactsService.statusByInterface(records: [
                BridgeRecord(
                    id: nil,
                    interface: "ghost0",
                    socketPath: nil,
                    plistExists: true,
                    daemonRunning: true,
                    status: "active",
                    updatedAt: "now",
                ),
            ])
            #expect(fromDB["ghost0"] == nil)
        #elseif os(macOS)
            let fromDB = HostBridgeFactsService.statusByInterface(records: [
                BridgeRecord(
                    id: nil,
                    interface: "en0",
                    socketPath: nil,
                    plistExists: true,
                    daemonRunning: true,
                    status: "active",
                    updatedAt: "now",
                ),
            ])
            #expect(fromDB["en0"] == "active")
        #endif
    }

    @Test func `unused bridged interface uniqueness lives in facts`() {
        let occupied = Network(
            id: "n1", name: "lab", mode: "bridged", bridge: "br0",
            macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
        )
        let err = #expect(throws: BarkVisorError.self) {
            try HostBridgeFactsService.requireUnusedBridgedInterface("br0", occupiedBy: occupied)
        }
        #expect(err?.httpStatus == 409)
        #expect(err?.errorDescription?.contains("lab") == true)
        #expect(throws: Never.self) {
            try HostBridgeFactsService.requireUnusedBridgedInterface("br0", occupiedBy: nil)
        }
    }

    @Test func `fallback readiness is not ready and uses shared constants`() {
        let ready = HostBridgeFactsService.fallbackReadiness()
        #expect(!ready.ready)
        #expect(ready.suggestedBridge == HostBridgeFactsService.suggestedBridgeName)
        #expect(ready.helperPath == HostBridgeFactsService.qemuBridgeHelperCandidates[0])
        #expect(ready.helperSetuid == false)
        #expect(ready.aclAllowsSuggested == false)
        #expect(ready.remediations?.isEmpty == false)
    }

    @Test func `adapter constants alias the facts module`() {
        #expect(LinuxHostNetwork.qemuBridgeHelperCandidates == HostBridgeFactsService.qemuBridgeHelperCandidates)
        #expect(LinuxHostNetwork.defaultBridgeACLPath == HostBridgeFactsService.defaultACLPath)
        #expect(HostBridgeReadinessService.suggestedBridgeName == HostBridgeFactsService.suggestedBridgeName)
    }
}
