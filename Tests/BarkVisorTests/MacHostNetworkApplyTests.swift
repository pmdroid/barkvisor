import Foundation
import Testing
@testable import BarkVisorCore

#if os(macOS)
    struct MacHostNetworkApplyTests {
        @Test func `parse static cidr and subnet mask`() throws {
            let parsed = try MacHostNetworkApply.parseStaticAddress("192.168.1.10/24")
            #expect(parsed.ip == "192.168.1.10")
            #expect(parsed.mask == "255.255.255.0")
            #expect(MacHostNetworkApply.subnetMask(prefixLength: 24) == "255.255.255.0")
        }

        @Test func `parse hardware ports from networksetup sample`() throws {
            let sample = """
            Hardware Port: Ethernet
            Device: en0
            Ethernet Address: aa:bb:cc:dd:ee:ff

            Hardware Port: Wi-Fi
            Device: en1
            Ethernet Address: 11:22:33:44:55:66
            """
            let ports = try MacHostNetworkApply.listHardwarePorts { _, _ in
                CommandResult(exitCode: 0, stdout: Data(sample.utf8), stderr: Data())
            }
            #expect(ports.count == 2)
            #expect(ports[0].name == "Ethernet")
            #expect(ports[0].device == "en0")
            #expect(MacHostNetworkApply.isWiFiPort("Wi-Fi"))
            #expect(!MacHostNetworkApply.isWiFiPort("Ethernet"))
        }

        @Test func `parse info value from getinfo text`() {
            let text = """
            Manual Configuration
            IP address: 192.168.1.10
            Subnet mask: 255.255.255.0
            Router: 192.168.1.1
            """
            #expect(MacHostNetworkApply.parseInfoValue(text, key: "IP address") == "192.168.1.10")
            #expect(MacHostNetworkApply.parseInfoValue(text, key: "Router") == "192.168.1.1")
        }

        @Test func `parse dns servers from networksetup output`() {
            #expect(MacHostNetworkApply.parseDNSServers("1.1.1.1\n8.8.8.8") == ["1.1.1.1", "8.8.8.8"])
            #expect(MacHostNetworkApply.parseDNSServers("There aren't any DNS Servers set on Wi-Fi.") == [])
        }

        @Test func `static apply runs setmanual then setdnsservers`() throws {
            let device = "en0-dns-apply-test"
            defer { MacHostNetworkApply.removeMarker(device: device) }
            var calls: [[String]] = []
            let run: (String, [String]) throws -> CommandResult = { path, args in
                if path == "/sbin/ifconfig" {
                    return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                #expect(path == MacHostNetworkApply.networksetupPath)
                calls.append(args)
                if args.first == "-getinfo" {
                    return CommandResult(exitCode: 0, stdout: Data("DHCP Configuration\n".utf8), stderr: Data())
                }
                if args.first == "-getdnsservers" {
                    return CommandResult(
                        exitCode: 0,
                        stdout: Data("There aren't any DNS Servers set on Ethernet.".utf8),
                        stderr: Data(),
                    )
                }
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }

            try MacHostNetworkApply.apply(
                device: device,
                service: "Ethernet",
                addressing: .staticIP,
                address: "192.168.1.10/24",
                gateway: "192.168.1.1",
                dns: ["1.1.1.1", "8.8.8.8"],
                run: run,
            )

            #expect(calls.contains(["-setmanual", "Ethernet", "192.168.1.10", "255.255.255.0", "192.168.1.1"]))
            #expect(calls.contains(["-setdnsservers", "Ethernet", "1.1.1.1", "8.8.8.8"]))
        }

        @Test func `revert restores saved dns servers`() throws {
            let device = "en0-dns-revert-test"
            defer { MacHostNetworkApply.removeMarker(device: device) }
            try MacHostNetworkApply.writeMarker(MacHostNetworkApply.Snapshot(
                device: device,
                service: "Ethernet",
                infoText: "DHCP Configuration\nIP address: 192.168.1.10\n",
                dnsServers: ["9.9.9.9"],
            ))

            var calls: [[String]] = []
            let run: (String, [String]) throws -> CommandResult = { _, args in
                calls.append(args)
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }

            let reverted = try MacHostNetworkApply.revert(device: device, run: run)
            #expect(reverted)
            #expect(calls.contains(["-setdhcp", "Ethernet"]))
            #expect(calls.contains(["-setdnsservers", "Ethernet", "9.9.9.9"]))
            #expect(MacHostNetworkApply.readMarker(device: device) == nil)
        }

        @Test func `revert removes applied ifconfig aliases before networksetup`() throws {
            let device = "en0-alias-revert-test"
            defer { MacHostNetworkApply.removeMarker(device: device) }
            try MacHostNetworkApply.writeMarker(MacHostNetworkApply.Snapshot(
                device: device,
                service: "Ethernet",
                infoText: "DHCP Configuration\n",
                dnsServers: [],
                appliedAliasCIDRs: ["10.0.0.2/24"],
            ))

            var calls: [[String]] = []
            let run: (String, [String]) throws -> CommandResult = { path, args in
                calls.append([path] + args)
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }

            let reverted = try MacHostNetworkApply.revert(device: device, run: run)
            #expect(reverted)
            #expect(calls.contains { $0 == ["/sbin/ifconfig", device, "-alias", "10.0.0.2"] })
            #expect(calls.contains { $0 == [MacHostNetworkApply.networksetupPath, "-setdhcp", "Ethernet"] })
            #expect(MacHostNetworkApply.readMarker(device: device) == nil)
        }

        @Test func `dhcp apply skips stale alias removal when lease is unknown`() throws {
            let device = "en0-dhcp-skip-stale"
            defer { MacHostNetworkApply.removeMarker(device: device) }
            var ifconfigCalls: [[String]] = []
            let run: (String, [String]) throws -> CommandResult = { path, args in
                if path == "/sbin/ifconfig" {
                    ifconfigCalls.append(args)
                    return CommandResult(
                        exitCode: 0,
                        stdout: Data("inet 192.168.1.10 netmask 0xffffff00\n".utf8),
                        stderr: Data(),
                    )
                }
                if args.first == "-getinfo" {
                    return CommandResult(exitCode: 0, stdout: Data("DHCP Configuration\n".utf8), stderr: Data())
                }
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            try MacHostNetworkApply.apply(
                device: device,
                service: "Ethernet",
                plan: HostInterfaceAddressApplyPlan(dhcpEnabled: true, dns: []),
                run: run,
            )
            #expect(!ifconfigCalls.contains { $0.contains("-alias") })
        }

        @Test func `revert restores aliases removed as stale`() throws {
            let device = "en0-stale-restore"
            defer { MacHostNetworkApply.removeMarker(device: device) }
            try MacHostNetworkApply.writeMarker(MacHostNetworkApply.Snapshot(
                device: device,
                service: "Ethernet",
                infoText: "DHCP Configuration\n",
                dnsServers: [],
                removedAliasCIDRs: ["10.0.0.2/24"],
            ))
            var calls: [[String]] = []
            let run: (String, [String]) throws -> CommandResult = { path, args in
                calls.append([path] + args)
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            let reverted = try MacHostNetworkApply.revert(device: device, run: run)
            #expect(reverted)
            #expect(calls.contains {
                $0 == ["/sbin/ifconfig", device, "alias", "10.0.0.2", "netmask", "255.255.255.0"]
            })
        }

        @Test func `failed revert keeps marker for retry`() throws {
            let device = "en0-dns-revert-fail-test"
            defer { MacHostNetworkApply.removeMarker(device: device) }
            try MacHostNetworkApply.writeMarker(MacHostNetworkApply.Snapshot(
                device: device,
                service: "Ethernet",
                infoText: "DHCP Configuration\n",
                dnsServers: [],
            ))

            let run: (String, [String]) throws -> CommandResult = { _, args in
                if args.first == "-setdhcp" {
                    return CommandResult(exitCode: 1, stdout: Data(), stderr: Data("fail".utf8))
                }
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }

            #expect(throws: (any Error).self) {
                try MacHostNetworkApply.revert(device: device, run: run)
            }
            #expect(MacHostNetworkApply.readMarker(device: device) != nil)
        }

        @Test func `equivalent commands include dns for static`() {
            let lines = MacHostNetworkApply.equivalentCommands(
                service: "Ethernet",
                device: "en0",
                addressing: .staticIP,
                address: "192.168.1.10/24",
                gateway: "192.168.1.1",
                dns: ["1.1.1.1"],
            )
            #expect(lines.joined(separator: "\n").contains("-setdnsservers"))
            #expect(lines.joined(separator: "\n").contains("1.1.1.1"))
        }
    }
#endif

struct MacHostBridgeApplyPlannerTests {
    #if os(macOS)
        @Test func `mac apply refuses wifi service`() {
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Wi-Fi",
                socketProbe: SocketVmnetApplyProbe(facts: facts, interface: "en0"),
            )
            let result = MacHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(action: .apply, nic: "en0"),
                probe: probe,
            )
            #expect(!result.success)
            #expect(result.message.contains("Wi-Fi"))
        }
        @Test func `mac apply plan lists dns when requested`() {
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
                    addressing: .staticIP,
                    address: "192.168.1.10/24",
                    gateway: "192.168.1.1",
                    dns: ["1.1.1.1"],
                ),
                probe: probe,
            )
            #expect(result.success)
            #expect(result.changes.contains(where: { $0.contains("DNS") }))
            #expect(result.commands.joined(separator: "\n").contains("-setdnsservers"))
            #expect(!result.changes.joined(separator: "\n").localizedCaseInsensitiveContains("socket_vmnet"))
            #expect(!result.commands.joined(separator: "\n").localizedCaseInsensitiveContains("socket_vmnet"))
        }

        @Test func `mac apply plan does not set up socket_vmnet`() {
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Ethernet",
                socketProbe: SocketVmnetApplyProbe(facts: facts, interface: "en0"),
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
            #expect(result.message.contains("Device address"))
            #expect(!result.message.localizedCaseInsensitiveContains("socket_vmnet"))
            #expect(result.commands.joined(separator: "\n").contains("ifconfig en0 alias"))
        }

        @Test func `mac delete stops socket_vmnet when createdBridge`() {
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [], createdBridge: true)],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Ethernet",
                socketProbe: SocketVmnetApplyProbe(facts: facts, interface: "en0"),
                createdBridge: true,
            )
            let result = MacHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(action: .delete, nic: "en0", confirm: true),
                probe: probe,
            )
            #expect(result.success)
            #expect(result.changes.contains { $0.contains("socket_vmnet") })
            #expect(result.message.contains("Keep"))
        }

        @Test func `mac revert foreign never stops socket_vmnet`() {
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Ethernet",
                socketProbe: SocketVmnetApplyProbe(facts: facts, interface: "en0"),
                createdBridge: false,
            )
            let revert = MacHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(action: .revert, nic: "en0", confirm: true),
                probe: probe,
            )
            #expect(revert.success)
            #expect(!revert.changes.contains { $0.lowercased().contains("stop") })
            #expect(revert.commands.contains { $0.contains("networksetup") })
            #expect(revert.commands.contains { $0.contains("never ip link del") })
            #expect(
                revert.changes.contains { $0.contains("Restore saved") }
                    || revert.changes.contains { $0.contains("DHCP") },
            )
            let denied = MacHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(action: .delete, nic: "en0", confirm: true),
                probe: probe,
            )
            #expect(!denied.success)
            #expect(denied.message.contains("foreign"))
        }

        @Test func `mac delete refuses attached Workloads`() {
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Ethernet",
                socketProbe: SocketVmnetApplyProbe(facts: facts, interface: "en0"),
                createdBridge: true,
            )
            let result = MacHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(
                    action: .delete,
                    nic: "en0",
                    confirm: true,
                    attachedWorkloadCount: 1,
                ),
                probe: probe,
            )
            #expect(result.conflict)
            #expect(result.message.contains("Workload"))
        }

        @Test func `mac live delete throws 409 when Workloads attached`() throws {
            let facts = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                bridges: [HostBridgeSnapshot(name: "en0", enslaved: [])],
                defaultRouteInterface: "en0",
                macSocketVmnet: true,
            ))
            let probe = MacHostBridgeApplyProbe(
                facts: facts,
                device: "en0",
                serviceName: "Ethernet",
                socketProbe: SocketVmnetApplyProbe(facts: facts, interface: "en0"),
                createdBridge: true,
            )
            do {
                _ = try MacHostBridgeApplyLive.run(
                    request: LinuxHostBridgeApplyRequest(
                        action: .delete,
                        nic: "en0",
                        confirm: true,
                        attachedWorkloadCount: 1,
                    ),
                    probe: probe,
                )
                Issue.record("expected conflict")
            } catch let error as BarkVisorError {
                #expect(error.httpStatus == 409)
            }
        }
    #endif
}
