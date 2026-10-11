import Foundation
import Testing
@testable import BarkVisorCore

struct NetworkdStaticConfigTests {
    @Test(arguments: [
        HostInterfaceAddressApplyPlan(staticCIDRs: ["192.0.2.2/24"], gateway: "192.0.2.1", dns: ["192.0.2.53"]),
        HostInterfaceAddressApplyPlan(dhcpEnabled: true),
        HostInterfaceAddressApplyPlan(dhcpEnabled: true, staticCIDRs: ["192.0.2.20/24"], dns: ["192.0.2.53"]),
    ])
    func `generated networkd units keep section headers on their own lines`(_ plan: HostInterfaceAddressApplyPlan) {
        let text = LinuxHostBridgeApply.networkdBridgeUnit(bridge: "brproof", plan: plan)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("[Network]"))
        #expect(!text.contains("[Network]Address="))
        #expect(!text.contains("[Network]DHCP="))
        if plan.dhcpEnabled {
            #expect(lines.contains("DHCP=yes"))
        }
        for cidr in plan.staticCIDRs {
            #expect(lines.contains("Address=\(cidr)"))
        }
        if let gateway = plan.gateway, !plan.dhcpEnabled {
            #expect(lines.contains("Gateway=\(gateway)"))
        }
        for dns in plan.dns {
            #expect(lines.contains("DNS=\(dns)"))
        }
    }
}
