import Foundation
import Testing
@testable import BarkVisorCore

struct HostInterfaceAddressApplyTests {
    @Test func `resolve legacy dhcp and static`() {
        let dhcp = HostInterfaceAddressApply.resolveLegacy(
            addressing: .dhcp,
            address: nil,
            gateway: nil,
            dns: ["1.1.1.1"],
        )
        guard case let .success(dhcpPlan) = dhcp else {
            Issue.record("expected dhcp plan")
            return
        }
        #expect(dhcpPlan.dhcpEnabled)
        #expect(dhcpPlan.staticCIDRs.isEmpty)

        let st = HostInterfaceAddressApply.resolveLegacy(
            addressing: .staticIP,
            address: "192.168.1.10/24",
            gateway: "192.168.1.1",
            dns: [],
        )
        guard case let .success(staticPlan) = st else {
            Issue.record("expected static plan")
            return
        }
        #expect(!staticPlan.dhcpEnabled)
        #expect(staticPlan.staticCIDRs == ["192.168.1.10/24"])
        #expect(staticPlan.gateway == "192.168.1.1")
    }

    @Test func `resolve dhcp plus static aliases`() {
        let result = HostInterfaceAddressApply.resolveFromAddresses(
            [
                HostInterfaceAddressApplyEntry(kind: .dhcp),
                HostInterfaceAddressApplyEntry(kind: .alias, cidr: "10.0.0.2/24"),
                HostInterfaceAddressApplyEntry(kind: .static, cidr: "192.168.30.50/24"),
            ],
            fallbackGateway: "192.168.1.1",
            fallbackDNS: ["1.1.1.1"],
        )
        guard case let .success(plan) = result else {
            Issue.record("expected success")
            return
        }
        #expect(plan.dhcpEnabled)
        #expect(plan.staticCIDRs == ["10.0.0.2/24", "192.168.30.50/24"])
        #expect(plan.aliasCIDRs == ["10.0.0.2/24", "192.168.30.50/24"])
    }

    @Test func `netplan yaml emits dhcp plus multi address`() {
        let yaml = HostInterfaceAddressApply.netplanYAML(
            bridge: "br0",
            nic: "eth0",
            plan: HostInterfaceAddressApplyPlan(
                dhcpEnabled: true,
                staticCIDRs: ["192.168.1.10/24", "10.0.0.2/24"],
                dns: ["1.1.1.1"],
            ),
        )
        #expect(yaml.contains("dhcp4: true"))
        #expect(yaml.contains("192.168.1.10/24"))
        #expect(yaml.contains("10.0.0.2/24"))
        #expect(yaml.contains("addresses: [1.1.1.1]"))
        #expect(!yaml.contains("via:"))
    }

    @Test func `planned diffs lists dhcp and aliases`() {
        let diffs = HostInterfaceAddressApply.plannedDiffs(
            plan: HostInterfaceAddressApplyPlan(
                dhcpEnabled: true,
                staticCIDRs: ["10.0.0.2/24"],
            ),
            interfaceLabel: "en0",
        )
        #expect(diffs.contains { $0.contains("DHCP") })
        #expect(diffs.contains { $0.contains("10.0.0.2/24") })
    }

    @Test func `linux check action includes address diffs`() {
        let probe = LinuxHostBridgeApplyProbe(
            facts: HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                helperPath: HostBridgeFactsService.qemuBridgeHelperCandidates[0],
                helperSetuid: true,
                aclAllowsSuggested: true,
                bridges: [HostBridgeSnapshot(name: "br0", enslaved: ["eth0"])],
                defaultRouteInterface: "eth0",
            )),
            backend: .netplan,
            existingInterfaces: ["eth0", "br0"],
        )
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .check,
                nic: "eth0",
                addresses: [
                    HostInterfaceAddressApplyEntry(kind: .dhcp),
                    HostInterfaceAddressApplyEntry(kind: .alias, cidr: "10.0.0.2/24"),
                ],
            ),
            probe: probe,
        )
        #expect(result.changes.contains { $0.contains("DHCP") })
        #expect(result.changes.contains { $0.contains("10.0.0.2/24") })
    }

    @Test func `mac planner lists alias commands`() {
        #if os(macOS)
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Ethernet",
                socketProbe: SocketVmnetApplyProbe(
                    facts: facts,
                    interface: "en0",
                    brewFormulaInstalled: true,
                    brewServiceLoaded: true,
                ),
            )
            let result = MacHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(
                    action: .apply,
                    nic: "en0",
                    addresses: [
                        HostInterfaceAddressApplyEntry(kind: .dhcp),
                        HostInterfaceAddressApplyEntry(kind: .alias, cidr: "10.0.0.2/24"),
                    ],
                ),
                probe: probe,
            )
            #expect(result.success)
            #expect(result.commands.joined(separator: "\n").contains("ifconfig en0 alias"))
        #endif
    }
}
