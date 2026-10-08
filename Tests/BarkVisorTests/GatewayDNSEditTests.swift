import Testing
@testable import BarkVisorCore

struct GatewayDNSEditTests {
    @Test func `gateway-only edit is rejected before success`() {
        let changes = LinuxHostBridgeApply.addressOnlyChanges(
            target: "eth0",
            plan: HostInterfaceAddressApplyPlan(staticCIDRs: ["192.0.2.10/24"], gateway: "192.0.2.1"),
        )
        #expect(changes.contains { $0.command.contains("rejected gateway/dns") })
    }

    @Test func `dns-only edit is rejected before success`() {
        let changes = LinuxHostBridgeApply.addressOnlyChanges(
            target: "eth0",
            plan: HostInterfaceAddressApplyPlan(dhcpEnabled: true, dns: ["192.0.2.53"]),
        )
        #expect(changes.contains { $0.command.contains("rejected gateway/dns") })
    }
}
