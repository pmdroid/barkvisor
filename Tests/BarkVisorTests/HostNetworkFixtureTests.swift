import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tier 1 host-network tests: golden fixtures + injected discovery + API JSON contracts.
@Suite("Host network fixtures")
struct HostNetworkFixtureTests {
    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/host-network")
    }

    private static func loadFixture(_ relative: String) throws -> String {
        let url = fixturesRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func loadJSON(_ relative: String) throws -> Data {
        try Data(contentsOf: fixturesRoot.appendingPathComponent(relative))
    }

    // MARK: - Linux parser golden files

    @Test func `linux netplan golden fixture parses multi-address dhcp`() throws {
        let yaml = try Self.loadFixture("linux/netplan-dhcp-plus-alias.yaml")
        let parsed = LinuxHostInterfaceAddressRead.parseNetplan(yaml, interface: "br0")
        #expect(parsed != nil)
        #expect(parsed?.dhcpEnabled == true)
        #expect(parsed?.gateway == "192.168.1.1")
        #expect(parsed?.dns == ["1.1.1.1"])
        #expect(parsed?.managedByBarkvisor == true)
        #expect(parsed?.addresses.map(\.cidr) == ["192.168.1.10/24", "10.0.0.2/24"])
        #expect(parsed?.addresses.map(\.source) == [.alias, .alias])
    }

    @Test func `linux nmcli golden fixtures parse dhcp and alias rows`() throws {
        let dhcp = try Self.loadFixture("linux/nmcli-dhcp.txt")
        let dhcpParsed = LinuxHostInterfaceAddressRead.parseNmcliDeviceShow(dhcp)
        #expect(dhcpParsed.dhcpEnabled)
        #expect(dhcpParsed.gateway == "192.168.30.1")
        #expect(dhcpParsed.dns == ["1.1.1.1"])
        #expect(!dhcpParsed.managedByBarkvisor)

        let alias = try Self.loadFixture("linux/nmcli-dhcp-plus-alias.txt")
        let aliasParsed = LinuxHostInterfaceAddressRead.parseNmcliDeviceShow(alias)
        #expect(aliasParsed.addresses.count == 2)
        // nmcli parser marks all rows dhcp when IP4.METHOD is auto; alias tagging is mergeLiveAddresses.
        #expect(aliasParsed.addresses[0].source == .dhcp)
        #expect(aliasParsed.addresses[1].source == .dhcp)
    }

    #if os(Linux)
        @Test func `discoverLinux prefers managed netplan fixture over nmcli`() throws {
            let yaml = try Self.loadFixture("linux/netplan-dhcp-plus-alias.yaml")
            let config = HostInterfaceAddressDiscovery.discoverLinux(
                interface: "br0",
                liveIPv4: ["192.168.1.10", "10.0.0.2"],
                readFile: { path in
                    path == LinuxHostBridgeApply.netplanPath ? yaml : nil
                },
                run: { _, _ in
                    Issue.record("nmcli should not run when netplan fixture matches")
                    return CommandResult(exitCode: 1, stdout: Data(), stderr: Data())
                },
            )
            #expect(config.managedByBarkvisor)
            #expect(config.dhcpEnabled)
            #expect(config.gateway == "192.168.1.1")
            #expect(config.addresses.count == 2)
            #expect(config.addresses[0].source == .dhcp)
            #expect(config.addresses[1].source == .alias)
        }

        @Test func `discoverLinux falls back to nmcli fixture when netplan absent`() throws {
            let nmcli = try Self.loadFixture("linux/nmcli-dhcp-plus-alias.txt")
            let config = HostInterfaceAddressDiscovery.discoverLinux(
                interface: "eth0",
                liveIPv4: ["192.168.30.50", "10.0.0.2"],
                readFile: { _ in nil },
                run: { path, args in
                    #expect(path == "/usr/bin/nmcli")
                    #expect(args == ["-t", "device", "show", "eth0"])
                    return CommandResult(exitCode: 0, stdout: Data(nmcli.utf8), stderr: Data())
                },
            )
            #expect(!config.managedByBarkvisor)
            #expect(config.dhcpEnabled)
            #expect(config.gateway == "192.168.30.1")
            #expect(config.dns == ["1.1.1.1"])
            #expect(config.addresses.count == 2)
        }
    #endif

    // MARK: - macOS parser golden files

    #if os(macOS)
        @Test func `macOS networksetup golden fixtures parse dhcp manual and aliases`() throws {
            let dhcpInfo = try Self.loadFixture("macos/networksetup-getinfo-dhcp.txt")
            let dhcpParsed = MacHostInterfaceAddressRead.parseGetInfo(dhcpInfo)
            #expect(dhcpParsed.dhcpEnabled)
            #expect(dhcpParsed.gateway == "192.168.30.1")
            #expect(dhcpParsed.staticCIDR == nil)

            let manualInfo = try Self.loadFixture("macos/networksetup-getinfo-manual.txt")
            let manualParsed = MacHostInterfaceAddressRead.parseGetInfo(manualInfo)
            #expect(!manualParsed.dhcpEnabled)
            #expect(manualParsed.staticCIDR == "192.168.1.10/24")

            let additional = try Self.loadFixture("macos/networksetup-additional-address.txt")
            #expect(MacHostInterfaceAddressRead.parseAdditionalAddresses(additional) == ["10.0.0.2/24"])

            let dns = try Self.loadFixture("macos/networksetup-dns.txt")
            #expect(MacHostNetworkApply.parseDNSServers(dns) == ["1.1.1.1", "8.8.8.8"])
        }

        @Test func `discoverMac injects networksetup golden fixtures end to end`() throws {
            let info = try Self.loadFixture("macos/networksetup-getinfo-dhcp.txt")
            let additional = try Self.loadFixture("macos/networksetup-additional-address.txt")
            let dns = try Self.loadFixture("macos/networksetup-dns.txt")
            let ports = [MacHostNetworkApply.HardwarePort(name: "Ethernet", device: "en0")]

            let config = HostInterfaceAddressDiscovery.discoverMac(
                interface: "en0",
                liveIPv4: ["192.168.30.50", "10.0.0.2"],
                ports: ports,
                run: { path, args in
                    #expect(path == MacHostNetworkApply.networksetupPath)
                    switch args.first {
                    case "-getinfo":
                        return CommandResult(exitCode: 0, stdout: Data(info.utf8), stderr: Data())
                    case "-getdnsservers":
                        return CommandResult(exitCode: 0, stdout: Data(dns.utf8), stderr: Data())
                    case "-listadditionalnetworkserviceaddress":
                        return CommandResult(exitCode: 0, stdout: Data(additional.utf8), stderr: Data())
                    default:
                        Issue.record("unexpected networksetup args: \(args)")
                        return CommandResult(exitCode: 1, stdout: Data(), stderr: Data())
                    }
                },
            )
            #expect(config.dhcpEnabled)
            #expect(config.gateway == "192.168.30.1")
            #expect(config.dns == ["1.1.1.1", "8.8.8.8"])
            #expect(config.addresses.count == 2)
            #expect(config.addresses[0].source == .dhcp)
            #expect(config.addresses[0].primary)
            #expect(config.addresses[1].source == .alias)
        }
    #endif

    // MARK: - API JSON contracts

    @Test func `bridge check request fixture decodes and evaluates to planned diffs`() throws {
        let body = try JSONDecoder().decode(
            BridgeRequest.self,
            from: Self.loadJSON("api/bridge-check-multi-address.request.json"),
        )
        #expect(body.action == "check")
        #expect(body.interface == "eth0")
        #expect(body.addresses?.count == 2)

        let request = try Self.bridgeApplyRequest(from: body, defaultAction: .check)
        #expect(request.action == LinuxHostBridgeApplyAction.check)
        #expect(request.nic == "eth0")
        #expect(request.addresses.count == 2)
        #expect(request.gateway == "192.168.1.1")
        #expect(request.dns == ["1.1.1.1"])

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
        let result = LinuxHostBridgeApply.evaluate(request: request, probe: probe)
        let response = BridgeActionResponse(
            success: result.success,
            message: result.message,
            applied: result.applied,
            needsConfirm: result.needsConfirm,
            backend: result.backend,
            changes: result.changes,
            warnings: result.warnings,
            commands: result.commands,
        )

        let encoded = try JSONEncoder().encode(response)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["success"] as? Bool == true)
        let changes = try #require(json["changes"] as? [String])
        #expect(changes.contains { $0.contains("DHCP") })
        #expect(changes.contains { $0.contains("10.0.0.2/24") })
    }

    @Test func `interfaces snapshot fixture matches HostInterface JSON contract`() throws {
        struct ExpectedAddress: Decodable {
            let cidr: String
            let source: String
            let primary: Bool
        }
        struct ExpectedInterface: Decodable {
            let name: String
            let displayName: String
            let ipAddress: String
            let dhcpEnabled: Bool
            let gateway: String?
            let dns: [String]
            let managedByBarkvisor: Bool
            let addresses: [ExpectedAddress]
        }

        let expected = try JSONDecoder().decode(
            ExpectedInterface.self,
            from: Self.loadJSON("api/interfaces-eth0.snapshot.json"),
        )

        var addressing = HostInterfaceAddressing(
            dhcpEnabled: expected.dhcpEnabled,
            gateway: expected.gateway,
            dns: expected.dns,
            managedByBarkvisor: expected.managedByBarkvisor,
        )
        addressing.addresses = expected.addresses.map {
            HostInterfaceAddressEntry(
                cidr: $0.cidr,
                source: HostInterfaceAddressSource(rawValue: $0.source) ?? .alias,
                primary: $0.primary,
            )
        }

        let dto = HostInterface(
            name: expected.name,
            displayName: expected.displayName,
            ipAddress: expected.ipAddress,
            bridgeStatus: nil,
            addresses: addressing.addresses.map {
                HostInterfaceAddressDTO(cidr: $0.cidr, source: $0.source.rawValue, primary: $0.primary)
            },
            dhcpEnabled: addressing.dhcpEnabled,
            gateway: addressing.gateway,
            dns: addressing.dns,
            managedByBarkvisor: addressing.managedByBarkvisor,
        )

        let encoded = try JSONEncoder().encode(dto)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["name", "displayName", "ipAddress", "dhcpEnabled", "gateway", "dns", "managedByBarkvisor", "addresses"] {
            #expect(json[key] != nil, "HostInterface JSON missing \(key)")
        }
        let addresses = try #require(json["addresses"] as? [[String: Any]])
        #expect(addresses.count == 2)
        #expect(addresses[0]["source"] as? String == "dhcp")
        #expect(addresses[0]["primary"] as? Bool == true)
        #expect(addresses[1]["source"] as? String == "alias")
    }

    private static func parseAddressApplyEntries(
        _ rows: [BridgeAddressRequest]?,
    ) throws -> [HostInterfaceAddressApplyEntry] {
        guard let rows, !rows.isEmpty else { return [] }
        return try rows.map { row in
            guard let kind = HostInterfaceAddressApplyKind(rawValue: row.kind) else {
                throw BarkVisorError.badRequest(
                    "addresses[].kind must be dhcp, static, or alias (got \"\(row.kind)\")",
                )
            }
            return HostInterfaceAddressApplyEntry(
                kind: kind,
                cidr: row.cidr,
                gateway: row.gateway,
                dns: row.dns,
            )
        }
    }

    private static func bridgeApplyRequest(
        from body: BridgeRequest,
        defaultAction: LinuxHostBridgeApplyAction,
    ) throws -> LinuxHostBridgeApplyRequest {
        let action: LinuxHostBridgeApplyAction = if body.dryRun == true {
            .dryRun
        } else if let raw = body.action?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            LinuxHostBridgeApplyAction(rawValue: raw) ?? defaultAction
        } else {
            defaultAction
        }
        let addressing: LinuxHostBridgeAddressing =
            body.addressing == LinuxHostBridgeAddressing.staticIP.rawValue ? .staticIP : .dhcp
        let addresses = try parseAddressApplyEntries(body.addresses)
        return LinuxHostBridgeApplyRequest(
            action: action,
            bridge: body.bridge ?? HostBridgeFactsService.suggestedBridgeName,
            nic: body.interface,
            addressing: addressing,
            address: body.address,
            gateway: body.gateway,
            dns: body.dns ?? [],
            addresses: addresses,
            confirm: body.confirm == true,
            deleteBridge: body.deleteBridge == true,
        )
    }
}
