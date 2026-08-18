import Foundation
import Testing
@testable import BarkVisorCore

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
}
