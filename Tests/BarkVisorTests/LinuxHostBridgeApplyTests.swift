import Foundation
import Testing
@testable import BarkVisorCore

struct LinuxHostBridgeApplyTests {
    private func facts(
        ready: Bool = false,
        onlyUplink: Bool = false,
        nic: String = "eth0",
    ) -> HostBridgeFacts {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            helperPath: HostBridgeFactsService.qemuBridgeHelperCandidates[0],
            helperSetuid: ready,
            aclAllowsSuggested: ready,
            bridges: ready ? [HostBridgeSnapshot(name: "br0", enslaved: [nic])] : [],
            defaultRouteInterface: nic,
        ))
    }

    private func probe(
        backend: LinuxNetworkBackend = .netplan,
        wireless: Set<String> = [],
        session: Set<String> = [],
        warnings: [String] = [],
        owned: Bool = false,
        createdBridge: Bool = false,
        nic: String = "eth0",
        ready: Bool = false,
        onlyUplink: Bool = false,
        liveIPv4CIDRs: [String] = [],
        keepIPv4CIDRs: [String] = [],
    ) -> LinuxHostBridgeApplyProbe {
        LinuxHostBridgeApplyProbe(
            facts: facts(ready: ready, onlyUplink: onlyUplink, nic: nic),
            backend: backend,
            wirelessNics: wireless,
            sessionRiskNics: session,
            sessionWarnings: warnings,
            owned: owned,
            createdBridge: createdBridge,
            existingInterfaces: ready ? [nic, "lo", "br0"] : [nic, "lo"],
            liveIPv4CIDRs: liveIPv4CIDRs,
            keepIPv4CIDRs: keepIPv4CIDRs,
        )
    }

    @Test func `refuse ifupdown and unknown`() {
        for backend: LinuxNetworkBackend in [.ifupdown, .unknown] {
            let result = LinuxHostBridgeApply.evaluate(
                request: LinuxHostBridgeApplyRequest(action: .apply, nic: "eth0"),
                probe: probe(backend: backend),
            )
            #expect(result.refused)
            #expect(!result.success)
            #expect(result.message.contains("Refuse"))
        }
    }

    @Test func `refuse Wi-Fi uplink`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .apply, nic: "wlan0"),
            probe: probe(wireless: ["wlan0"], nic: "wlan0"),
        )
        #expect(result.refused)
        #expect(result.message.contains("Wi-Fi"))
    }

    @Test func `netplanYAML writes Device static address`() {
        let yaml = LinuxHostBridgeApply.netplanYAML(
            bridge: "br0",
            nic: "eth0",
            addressing: .staticIP,
            address: "192.168.1.10/24",
            gateway: "192.168.1.1",
            dns: ["1.1.1.1"],
        )
        #expect(yaml.contains("addresses: [192.168.1.10/24]"))
        #expect(yaml.contains("via: 192.168.1.1"))
        #expect(yaml.contains("addresses: [1.1.1.1]"))
        #expect(!yaml.contains("dhcp4: true"))
    }

    @Test func `rollback helper keeps config only after commit stamp`() {
        #expect(LinuxHostBridgeApply.commitStampPath(bridge: "br0").hasSuffix("host-network/br0-commit"))
        let script = LinuxHostBridgeApply.rollbackHelperScript(bridge: "br0", dataDir: "/var/lib/barkvisor")
        #expect(script.contains("host-network/br0-commit"))
        #expect(script.contains("then exit 0"))
        #expect(script.contains("nmcli connection delete barkvisor-br0"))
        #expect(script.contains("grep \"^barkvisor-br0-\""))
        #expect(script.contains("netplan apply"))
    }

    @Test func `static host address is Device not guest`() {
        let missing = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .dryRun, nic: "eth0", addressing: .staticIP),
            probe: probe(),
        )
        #expect(missing.refused)
        #expect(missing.message.contains("Device"))
        #expect(!missing.message.lowercased().contains("guest static"))

        let ok = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .dryRun,
                nic: "eth0",
                addressing: .staticIP,
                address: "192.168.1.10/24",
                gateway: "192.168.1.1",
                dns: ["1.1.1.1"],
                confirm: true,
            ),
            probe: probe(),
        )
        #expect(ok.success)
        #expect(ok.changes.contains { $0.contains("Device") })
        #expect(ok.changes.contains { $0.contains("not the guest") })
    }

    @Test func `SSH or SPA on NIC requires confirm`() {
        let pending = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .apply, nic: "eth0"),
            probe: probe(
                session: ["eth0"],
                warnings: ["SSH looks active on the default-route NIC (eth0)."],
            ),
        )
        #expect(!pending.success)
        #expect(pending.needsConfirm)
        #expect(pending.warnings.contains { $0.contains("auto-revert") })
        #expect(!pending.applied)

        let confirmed = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .dryRun, nic: "eth0", confirm: true),
            probe: probe(session: ["eth0"]),
        )
        #expect(confirmed.success)
        #expect(!confirmed.needsConfirm)
        #expect(confirmed.commands.contains { $0.contains("netplan try") })
        #expect(!confirmed.commands.contains { $0.contains("netplan apply") })
    }

    @Test func `revert never deletes a shared br0`() {
        let missing = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .revert),
            probe: probe(owned: false),
        )
        #expect(missing.refused)
        #expect(missing.message.contains("shared"))

        let force = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .revert, confirm: true, deleteBridge: true),
            probe: probe(owned: true),
        )
        #expect(force.refused)
        #expect(force.message.contains("Refuse default-delete"))

        let ok = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .revert, confirm: true),
            probe: probe(owned: true),
        )
        #expect(ok.success)
        #expect(ok.changes.contains { $0.contains("Leave br0") || $0.contains("never default-deleted") })
    }

    @Test func `check reports facts without writing`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .check, nic: "eth0"),
            probe: probe(ready: true),
        )
        #expect(result.success)
        #expect(!result.applied)
        #expect(result.changes.contains { $0.contains("backend=netplan") })
    }

    @Test func `ACL merge is marker-tagged and strip is precise`() {
        let merged = LinuxHostBridgeApply.mergeACL(existing: "allow virbr0\n", bridge: "br0")
        #expect(merged.contains(LinuxHostBridgeApply.aclMarker))
        #expect(merged.contains("allow br0"))
        #expect(merged.contains("allow virbr0"))
        let stripped = LinuxHostBridgeApply.stripMarkedACL(existing: merged, bridge: "br0")
        #expect(!stripped.contains(LinuxHostBridgeApply.aclMarker))
        #expect(!stripped.contains("allow br0"))
        #expect(stripped.contains("allow virbr0"))
    }

    @Test func `detectBackend prefers netplan then NM then networkd`() {
        #expect(LinuxHostBridgeApply.detectBackend(
            netplanDir: "/no/netplan",
            nmcli: "/no/nmcli",
            networkdRun: "/no/netif",
            interfacesFile: "/no/interfaces",
            fileExists: { _ in false },
        ) == .unknown)
        #expect(LinuxHostBridgeApply.detectBackend(
            netplanDir: "/etc/netplan",
            fileExists: { $0 == "/etc/netplan" },
        ) == .netplan)
        #expect(LinuxHostBridgeApply.detectBackend(
            netplanDir: "/no",
            nmcli: "/usr/bin/nmcli",
            fileExists: { $0 == "/usr/bin/nmcli" },
        ) == .networkManager)
        #expect(LinuxHostBridgeApply.detectBackend(
            netplanDir: "/no",
            nmcli: "/no",
            networkdRun: "/run/systemd/netif",
            fileExists: { $0 == "/run/systemd/netif" },
        ) == .systemdNetworkd)
        #expect(LinuxHostBridgeApply.detectBackend(
            netplanDir: "/no",
            nmcli: "/no",
            networkdRun: "/no",
            interfacesFile: "/etc/network/interfaces",
            fileExists: { $0 == "/etc/network/interfaces" },
        ) == .ifupdown)
    }

    @Test func `detectActiveBackend uses the manager that owns the NIC`() {
        #expect(LinuxHostBridgeApply.detectActiveBackend(
            nic: "enp2s0",
            nmManaged: true,
            networkdManages: false,
            installed: { .netplan },
        ) == .networkManager)
        #expect(LinuxHostBridgeApply.detectActiveBackend(
            nic: "enp2s0",
            nmManaged: false,
            networkdManages: true,
            installed: { .netplan },
        ) == .systemdNetworkd)
        #expect(LinuxHostBridgeApply.detectActiveBackend(
            nic: "eth0",
            nmManaged: false,
            networkdManages: false,
            installed: { .netplan },
        ) == .netplan)
        #expect(LinuxHostBridgeApply.detectActiveBackend(
            nic: "eth0",
            nmManaged: true,
            networkdManages: true,
            installed: { .netplan },
        ) == .networkManager)
    }

    @Test func `tcp table parser finds SSH and SPA listen`() {
        let table = """
        sl  local_address rem_address   st
           0: 0100007F:1E61 00000000:0000 0A
           1: 00000000:0016 00000000:0000 0A
           2: 010011AC:C1C0 020011AC:0016 01
        """
        #expect(LinuxHostBridgeApply.tcpTableHasPort(contents: table, port: 7_777, established: false))
        #expect(LinuxHostBridgeApply.tcpTableHasPort(contents: table, port: 22, established: false))
        #expect(LinuxHostBridgeApply.tcpTableHasPort(contents: table, port: 22, established: true))
        #expect(!LinuxHostBridgeApply.tcpTableHasPort(contents: table, port: 80, established: false))
    }

    @Test func `commit requires pending apply`() {
        let missing = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .commit),
            probe: probe(owned: true),
        )
        #expect(!missing.success)
        #expect(missing.refused)
        #expect(missing.message.contains("No pending"))
    }

    @Test func `live mutator records without touching the host`() throws {
        let recorder = RecordingLinuxHostBridgeMutator()
        let result = try LinuxHostBridgeApplyLive.run(
            request: LinuxHostBridgeApplyRequest(action: .apply, nic: "eth0", confirm: true),
            probe: probe(),
            mutator: recorder,
        )
        #expect(result.applied)
        #expect(result.success)
        #expect(recorder.steps.contains { $0.contains("action=apply") })
        #expect(recorder.steps.contains { $0.contains("netplan") })
    }

    @Test func `live apply keeps a pending window when nic would drop SSH`() throws {
        let recorder = RecordingLinuxHostBridgeMutator()
        let result = try LinuxHostBridgeApplyLive.run(
            request: LinuxHostBridgeApplyRequest(action: .apply, nic: "enp2s0", confirm: true),
            probe: probe(session: ["enp2s0"], nic: "enp2s0"),
            mutator: recorder,
        )
        #expect(result.applied)
        #expect(result.success)
        #expect(result.pendingCommit)
        #expect(result.createdBridge)
        #expect(result.rollbackSeconds == 60)
        #expect(result.message.contains("auto-revert"))
        #expect(!result.message.contains("kept it"))
    }

    @Test func `check includes address diffs when addresses provided`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .check,
                nic: "eth0",
                addresses: [
                    HostInterfaceAddressApplyEntry(kind: .dhcp),
                    HostInterfaceAddressApplyEntry(kind: .alias, cidr: "10.0.0.2/24"),
                ],
            ),
            probe: probe(ready: true),
        )
        #expect(result.changes.contains { $0.contains("10.0.0.2/24") })
    }

    @Test func `wireless sysfs helper`() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("wlan0/wireless"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("eth0"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LinuxHostNetwork.isWirelessInterface("wlan0", netClass: dir.path))
        #expect(!LinuxHostNetwork.isWirelessInterface("eth0", netClass: dir.path))
        #expect(!LinuxHostNetwork.isWirelessInterface("../etc", netClass: dir.path))
    }

    @Test func `host mutation flag is the Linux apply gate`() {
        #if os(Linux) || os(macOS)
            #expect(PlatformCapabilities.supportsHostMutation)
            try? PlatformCapabilities.requireHostMutation()
        #endif
        #if os(Linux)
            #expect(!PlatformCapabilities.supportsManagedBridgeDaemon)
        #endif
    }

    @Test func `br1 apply writes per-bridge ACL pending and netplan paths`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .dryRun,
                bridge: "br1",
                nic: "eth1",
                confirm: true,
            ),
            probe: LinuxHostBridgeApplyProbe(
                facts: facts(nic: "eth1"),
                backend: .netplan,
                existingInterfaces: ["eth1", "lo", "br0"],
            ),
        )
        #expect(result.success)
        #expect(!result.conflict)
        #expect(result.changes.contains { $0.contains("90-barkvisor-br1.yaml") })
        #expect(!result.changes.contains { $0.contains("90-barkvisor-br0.yaml") })
        #expect(result.commands.contains { $0.contains("# barkvisor:allow-br1") })
        #expect(!result.commands.contains { $0.contains("# barkvisor:allow-br0") })
        #expect(LinuxHostBridgeApply.netplanPath(bridge: "br1") == "/etc/netplan/90-barkvisor-br1.yaml")
        #expect(LinuxHostBridgeApply.networkdPortPath(nic: "eth1") == "/etc/systemd/network/90-barkvisor-eth1.network")
        #expect(LinuxHostBridgeApply.nmSlaveConnectionName(bridge: "br1", nic: "eth1") == "barkvisor-br1-eth1")
        #expect(HostNetworkPendingCommitService.linuxPendingPath(bridge: "br1").hasSuffix("host-network/br1-pending.json"))
        #expect(LinuxHostBridgeApply.aclMarker(for: "br1") == "# barkvisor:allow-br1")
    }

    @Test func `createdBridge is true for br1 when foreign br0 exists`() {
        let probe = LinuxHostBridgeApplyProbe(
            facts: HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                helperPath: HostBridgeFactsService.qemuBridgeHelperCandidates[0],
                helperSetuid: true,
                aclAllowsSuggested: true,
                bridges: [HostBridgeSnapshot(name: "br0", enslaved: ["eth0"])],
                defaultRouteInterface: "eth0",
            )),
            backend: .netplan,
            existingInterfaces: ["eth0", "lo", "br0"],
        )
        #expect(!LinuxHostBridgeApply.createdBridge(
            named: "br0",
            existingInterfaces: probe.existingInterfaces,
            factsBridges: probe.facts.bridges,
        ))
        #expect(LinuxHostBridgeApply.createdBridge(
            named: "br1",
            existingInterfaces: probe.existingInterfaces,
            factsBridges: probe.facts.bridges,
        ))
        #expect(LinuxHostBridgeApply.createdBridgeForApply(
            request: LinuxHostBridgeApplyRequest(action: .apply, bridge: "br1", nic: "eth1", confirm: true),
            probe: probe,
        ))
        #expect(!probe.facts.bridges.isEmpty)
    }

    @Test func `systemd-networkd units for br0 are found and port files rewritten`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [NetDev]
        Name=br0
        Kind=bridge
        """.write(toFile: "\(dir.path)/10-br0.netdev", atomically: true, encoding: .utf8)
        try """
        [Match]
        Name=enp2s0

        [Network]
        Bridge=br0
        """.write(toFile: "\(dir.path)/20-enp2s0.network", atomically: true, encoding: .utf8)
        try """
        [Match]
        Name=br0

        [Network]
        Address=192.168.30.1/16
        DHCP=yes
        """.write(toFile: "\(dir.path)/25-br0.network", atomically: true, encoding: .utf8)
        let persist = LinuxHostBridgeApply.systemdBridgePersist(bridge: "br0", dir: dir.path)
        #expect(Set(persist.remove.map { ($0 as NSString).lastPathComponent }) == [
            "10-br0.netdev",
            "25-br0.network",
        ])
        #expect(persist.rewrite.map { ($0 as NSString).lastPathComponent } == ["20-enp2s0.network"])
        let rewritten = try LinuxHostBridgeApply.rewritePortNetworkDroppingBridge(
            String(contentsOfFile: persist.rewrite[0], encoding: .utf8),
            bridge: "br0",
            cidrs: ["192.168.30.1/16"],
        )
        #expect(!rewritten.contains("Bridge=br0"))
        #expect(rewritten.contains("Address=192.168.30.1/16"))
        #expect(rewritten.contains("DHCP=yes"))
        let nmFiles = LinuxHostAddressPersist.persistFiles(
            interface: "br0",
            cidrs: ["192.168.33.13/16"],
            backend: .networkManager,
            dir: dir.path,
        )
        #expect(nmFiles.isEmpty)
        let files = LinuxHostAddressPersist.persistFiles(
            interface: "br0",
            cidrs: ["192.168.33.13/16"],
            backend: .systemdNetworkd,
            dir: dir.path,
        )
        #expect(files.contains { $0.path.hasSuffix("25-br0.network.d/90-barkvisor-aliases.conf") })
        #expect(files.contains { $0.body.contains("Address=192.168.33.13/16") })
        let preview = LinuxHostAddressPersist.previewCommands(
            interface: "eth0",
            cidrs: ["10.0.0.2/24"],
            backend: .netplan,
        )
        #expect(preview.contains { $0.command.contains("90-barkvisor-eth0-aliases.yaml") })
        #expect(preview.contains { $0.command.contains("ip addr add 10.0.0.2/24 dev eth0") })
        #expect(LinuxHostAddressPersist.ipAddrAddAlreadyPresent(
            "Error: ipv4: Address already assigned.\n",
        ))
        #expect(LinuxHostAddressPersist.cidrsNotOnDevice(
            ["192.168.30.1/16", "192.168.33.13/16"],
            live: ["192.168.30.1/16"],
        ) == ["192.168.33.13/16"])
        #expect(LinuxHostAddressPersist.cidrsToRemove(
            desired: ["192.168.30.1/16"],
            live: ["192.168.8.163/16", "192.168.30.1/16", "192.168.8.201/16"],
            keep: ["192.168.8.163/16"],
        ) == ["192.168.8.201/16"])
        let drop = LinuxHostAddressPersist.previewCommands(
            interface: "enp2s0",
            cidrs: ["192.168.30.1/16"],
            backend: .networkManager,
            liveCIDRs: ["192.168.8.163/16", "192.168.30.1/16", "192.168.8.201/16"],
            keepCIDRs: ["192.168.8.163/16"],
        )
        #expect(drop.contains { $0.command.contains("ip addr del 192.168.8.201/16 dev enp2s0") })
        #expect(drop.contains { $0.command.contains("-ipv4.addresses 192.168.8.201/16") })
        #expect(!drop.contains { $0.command.contains("ip addr add 192.168.30.1/16") })
        #expect(!drop.contains { $0.command.contains("+ipv4.addresses 192.168.30.1/16") })
        #expect(!drop.contains { $0.command.contains("192.168.8.163") })
        let helper = LinuxHostBridgeApply.addressRollbackHelperScript(
            device: "enp2s0",
            iface: "enp2s0",
            cidrs: ["10.0.0.2/24"],
            persistFiles: ["/tmp/x"],
            restoreCIDRs: ["192.168.8.201/16"],
        )
        #expect(helper.contains("ip addr del 10.0.0.2/24"))
        #expect(helper.contains("ip addr add 192.168.8.201/16"))
        #expect(helper.contains("rm -rf /tmp/x"))
        let restore = LinuxHostBridgeApply.addressRollbackHelperScript(
            device: "enp2s0",
            iface: "enp2s0",
            cidrs: ["192.168.89.163/16"],
            restoreCIDRs: ["192.168.8.163/16"],
            persistRestore: [(
                path: "/etc/systemd/network/20-enp2s0.network.d/90-barkvisor-aliases.conf",
                previous: "Address=192.168.8.163/16\n",
            )],
            nmConnection: "enp2s0",
        )
        #expect(restore.contains("+ipv4.addresses 192.168.8.163/16"))
        #expect(restore.contains("-ipv4.addresses 192.168.89.163/16"))
        #expect(restore.contains("Address=192.168.8.163/16"))
        #expect(!restore.contains("rm -rf /etc/systemd/network/20-enp2s0.network.d/90-barkvisor-aliases.conf"))
    }

    @Test func `acl tag without marker is leftover we can delete`() throws {
        let tagged = LinuxHostBridgeApply.ownership(
            bridge: "br0",
            marker: nil,
            acl: "# barkvisor:allow-br0\nallow br0\n",
        )
        #expect(tagged.owned)
        #expect(tagged.createdBridge)
        let foreign = LinuxHostBridgeApply.ownership(
            bridge: "br0",
            marker: nil,
            acl: "allow br0\n",
        )
        #expect(!foreign.owned)
        #expect(!foreign.createdBridge)
        let attached = LinuxHostBridgeApply.ownership(
            bridge: "br0",
            marker: LinuxHostBridgeApply.OwnerMarker(bridge: "br0", uplink: "eth0", createdBridge: false),
            acl: "# barkvisor:allow-br0\nallow br0\n",
        )
        #expect(attached.owned)
        #expect(!attached.createdBridge)
        let leftover = LinuxHostBridgeApply.ownership(
            bridge: "br0",
            marker: nil,
            acl: nil,
            leftoverPersist: true,
        )
        #expect(leftover.owned)
        #expect(leftover.createdBridge)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [NetDev]
        Name=br0
        Kind=bridge
        """.write(toFile: "\(dir.path)/10-br0.netdev", atomically: true, encoding: .utf8)
        #expect(LinuxHostBridgeApply.leftoverHostBridge(bridge: "br0", dir: dir.path))
        #expect(!LinuxHostBridgeApply.leftoverHostBridge(bridge: "br1", dir: dir.path))
    }

    @Test func `apply create-equivalent 409 when name exists`() throws {
        let taken = LinuxHostBridgeApplyProbe(
            facts: HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
                helperPath: HostBridgeFactsService.qemuBridgeHelperCandidates[0],
                helperSetuid: true,
                aclAllowsSuggested: true,
                bridges: [HostBridgeSnapshot(name: "br0", enslaved: ["eth0"])],
                defaultRouteInterface: "eth0",
            )),
            backend: .netplan,
            existingInterfaces: ["eth0", "eth1", "lo", "br0"],
        )
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .apply, bridge: "br0", nic: "eth1", confirm: true),
            probe: taken,
        )
        #expect(result.conflict)
        #expect(result.refused)
        #expect(result.message.contains("already exists"))

        let owned = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .apply, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(owned: true, ready: true),
        )
        #expect(!owned.conflict)
        #expect(owned.success)

        do {
            _ = try LinuxHostBridgeApplyLive.run(
                request: LinuxHostBridgeApplyRequest(action: .apply, bridge: "br0", nic: "eth1", confirm: true),
                probe: taken,
                mutator: RecordingLinuxHostBridgeMutator(),
            )
            Issue.record("expected conflict")
        } catch let error as BarkVisorError {
            #expect(error.httpStatus == 409)
        }
    }

    @Test func `extra address on existing unowned br0 does not create the bridge`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .apply,
                bridge: "br0",
                nic: "eth0",
                addresses: [
                    HostInterfaceAddressApplyEntry(kind: .dhcp),
                    HostInterfaceAddressApplyEntry(kind: .alias, cidr: "10.0.0.2/24"),
                ],
                confirm: true,
            ),
            probe: probe(ready: true),
        )
        #expect(result.success)
        #expect(!result.conflict)
        #expect(result.commands.contains { $0.contains("ip addr add 10.0.0.2/24 dev br0") })
        #expect(result.commands.contains { $0.contains("90-barkvisor-br0-aliases.yaml") })
        #expect(!result.commands.contains { $0.contains("nmcli connection add type bridge") })
        #expect(!result.message.contains("already exists"))
    }

    @Test func `uplink apply without bridge name adds addresses`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .apply,
                bridge: "",
                nic: "eth0",
                addresses: [
                    HostInterfaceAddressApplyEntry(kind: .dhcp),
                    HostInterfaceAddressApplyEntry(kind: .alias, cidr: "10.0.0.2/24"),
                ],
                confirm: true,
            ),
            probe: probe(),
        )
        #expect(result.success)
        #expect(!result.conflict)
        #expect(result.commands.contains { $0.contains("ip addr add 10.0.0.2/24 dev eth0") })
        #expect(result.commands.contains { $0.contains("90-barkvisor-eth0-aliases.yaml") })
        #expect(!result.changes.contains { $0.contains("netplan try") })
    }

    @Test func `uplink apply drops extras removed from the form`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .dryRun,
                bridge: "",
                nic: "enp2s0",
                addresses: [
                    HostInterfaceAddressApplyEntry(kind: .dhcp),
                    HostInterfaceAddressApplyEntry(kind: .alias, cidr: "192.168.30.1/16"),
                ],
                confirm: true,
            ),
            probe: probe(
                backend: .networkManager,
                nic: "enp2s0",
                liveIPv4CIDRs: [
                    "192.168.8.163/16",
                    "192.168.30.1/16",
                    "192.168.8.201/16",
                ],
                keepIPv4CIDRs: ["192.168.8.163/16"],
            ),
        )
        #expect(result.success)
        #expect(result.commands.contains { $0.contains("ip addr del 192.168.8.201/16 dev enp2s0") })
        #expect(result.commands.contains { $0.contains("-ipv4.addresses 192.168.8.201/16") })
        #expect(!result.commands.contains { $0.contains("ip addr add 192.168.30.1/16") })
        #expect(!result.commands.contains { $0.contains("ip addr del 192.168.8.163") })
    }

    @Test func `next-free skips sysfs and markers`() throws {
        #expect(LinuxHostBridgeApply.nextFreeBridge(existingInterfaces: [], markerBridges: []) == "br0")
        #expect(LinuxHostBridgeApply.nextFreeBridge(
            existingInterfaces: ["br0", "eth0"],
            markerBridges: [],
        ) == "br1")
        #expect(LinuxHostBridgeApply.nextFreeBridge(
            existingInterfaces: ["br0"],
            markerBridges: ["br1"],
        ) == "br2")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? Data("{\"bridge\":\"br0\"}".utf8).write(to: dir.appendingPathComponent("host-bridge-br0.json"))
        try? Data("{\"bridge\":\"br2\"}".utf8).write(to: dir.appendingPathComponent("host-bridge-br2.json"))
        #expect(LinuxHostBridgeApply.listedMarkerBridges(dataDir: dir) == ["br0", "br2"])
        #expect(LinuxHostBridgeApply.nextFreeBridge(
            existingInterfaces: LinuxHostBridgeApply.listedMarkerBridges(dataDir: dir),
            markerBridges: LinuxHostBridgeApply.listedMarkerBridges(dataDir: dir),
        ) == "br1")
        try LinuxHostBridgeApply.writeOwnerMarker(
            bridge: "br1", uplink: "en0", createdBridge: true, dataDir: dir,
        )
        let marker = LinuxHostBridgeApply.readOwnerMarker(bridge: "br1", dataDir: dir)
        #expect(marker?.bridge == "br1")
        #expect(marker?.uplink == "en0")
        #expect(marker?.createdBridge == true)
        #expect(LinuxHostBridgeApply.listOwnerMarkers(dataDir: dir).contains(where: { $0.bridge == "br1" }))
        #expect(LinuxHostBridgeApply.nextFreeBridgeLive(
            facts: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()),
            dataDir: dir,
            extraTaken: ["br0", "br1", "br2"],
        ) == "br3")
    }

    @Test func `dropsManagementSession when nic carries SSH or is the only uplink`() {
        let session = probe(session: ["enp2s0"], nic: "enp2s0")
        #expect(LinuxHostBridgeApply.dropsManagementSession(nic: "enp2s0", probe: session))
        let only = probe(nic: "eth0", onlyUplink: true)
        #expect(LinuxHostBridgeApply.dropsManagementSession(nic: "eth0", probe: only))
        let safe = probe(nic: "eth1", ready: true)
        #expect(!LinuxHostBridgeApply.dropsManagementSession(nic: "eth1", probe: safe))
    }

    @Test func `pending path lives in dataDir host-network`() {
        #expect(HostNetworkPendingCommitService.linuxPendingPath(bridge: "br1").contains("/host-network/br1-pending.json"))
        #expect(LinuxHostBridgeApply.commitStampPath(bridge: "br1").contains("/host-network/br1-commit"))
    }

    @Test func `one pending commit per Device`() {
        let br0 = HostNetworkPendingCommitService.makePending(target: "br0")
        let br1 = HostNetworkPendingCommitService.makePending(target: "br1")
        #expect(HostNetworkPendingCommitService.blockingPending(target: "br1", existing: [br0])?.target == "br0")
        #expect(HostNetworkPendingCommitService.blockingPending(target: "br0", existing: [br0]) == nil)
        let expired = HostNetworkPendingCommit(
            target: "br0",
            commitDeadline: Date().addingTimeInterval(-1),
            rollbackSeconds: 60,
        )
        #expect(HostNetworkPendingCommitService.blockingPending(target: "br1", existing: [expired]) == nil)
    }

    @Test func `ACL merge for br1 leaves br0 marker`() {
        let br0 = LinuxHostBridgeApply.mergeACL(existing: "allow virbr0\n", bridge: "br0")
        let both = LinuxHostBridgeApply.mergeACL(existing: br0, bridge: "br1")
        #expect(both.contains("# barkvisor:allow-br0"))
        #expect(both.contains("# barkvisor:allow-br1"))
        #expect(both.contains("allow br0"))
        #expect(both.contains("allow br1"))
        let stripped = LinuxHostBridgeApply.stripMarkedACL(existing: both, bridge: "br1")
        #expect(stripped.contains("# barkvisor:allow-br0"))
        #expect(!stripped.contains("# barkvisor:allow-br1"))
        #expect(stripped.contains("allow br0"))
        #expect(!stripped.contains("allow br1"))
    }

    @Test func `path parameter is the bridge name on Linux`() {
        let linux = LinuxHostBridgeApply.resolveNames(
            bodyBridge: nil,
            bodyInterface: "eth1",
            pathInterface: "br1",
            linuxHost: true,
        )
        #expect(linux.bridge == "br1")
        #expect(linux.nic == "eth1")
        let omitted = LinuxHostBridgeApply.resolveNames(
            bodyBridge: nil,
            bodyInterface: "eth0",
            pathInterface: nil,
            linuxHost: true,
        )
        #expect(omitted.bridge.isEmpty)
        #expect(omitted.nic == "eth0")
        #expect(omitted.bridge != HostBridgeFactsService.suggestedBridgeName)
        let mac = LinuxHostBridgeApply.resolveNames(
            bodyBridge: nil,
            bodyInterface: nil,
            pathInterface: "en0",
            linuxHost: false,
        )
        #expect(mac.bridge.isEmpty)
        #expect(mac.nic == "en0")
    }

    @Test func `rollback helper is per-bridge`() {
        let script = LinuxHostBridgeApply.rollbackHelperScript(bridge: "br1", dataDir: "/var/lib/barkvisor")
        #expect(script.contains("/etc/netplan/90-barkvisor-br1.yaml"))
        #expect(script.contains("barkvisor-br1"))
        #expect(script.contains("host-bridge-br1.json"))
        #expect(script.contains("host-network/br1-pending.json"))
        #expect(script.contains("grep \"^barkvisor-br1-\""))
        #expect(script.contains("90-barkvisor-\"$uplink\".network"))
        #expect(script.contains("nmcli device reapply"))
        #expect(!script.contains("90-barkvisor-br0.yaml"))
    }

    @Test func `owned delete detaches ports and ip link dels`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .delete, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(owned: true, createdBridge: true, ready: true),
        )
        #expect(result.success)
        #expect(!result.refused)
        #expect(result.changes.contains { $0.contains("Detach eth0") })
        #expect(result.changes.contains { $0.contains("Restore L3") })
        #expect(result.commands.contains { $0.contains("ip link delete br0 type bridge") })
        #expect(result.commands.contains { $0.contains("DELETE /api/networks (bridge=br0)") })
        #expect(result.message.contains("Ready to delete"))
        #expect(!result.message.contains("Keep changes"))
    }

    @Test func `owned delete restores NM slave and networkd port L3`() {
        let nm = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .delete, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(backend: .networkManager, owned: true, createdBridge: true, ready: true),
        )
        #expect(nm.success)
        func idx(_ pred: (String) -> Bool) -> Int {
            nm.commands.firstIndex(where: pred) ?? 9_999
        }
        #expect(idx { $0.contains("nomaster") } < idx { $0.contains("barkvisor-br0-eth0") })
        #expect(idx { $0.contains("barkvisor-br0-eth0") } < idx { $0.hasSuffix("barkvisor-br0") })
        #expect(idx { $0.hasSuffix("barkvisor-br0") } < idx { $0.contains("ip link delete br0 type bridge") })
        #expect(idx { $0.contains("ip link delete br0 type bridge") } < idx { $0.contains("nmcli connection up eth0") })
        #expect(idx { $0.contains("nmcli connection up eth0") } < idx { $0.contains("nmcli device reapply eth0") })
        #expect(nm.commands.contains { $0.contains("ip addr add") && $0.contains("eth0") })
        #expect(nm.commands.contains { $0.contains("ipv4.method auto") })
        let networkd = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .delete, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(backend: .systemdNetworkd, owned: true, createdBridge: true, ready: true),
        )
        #expect(networkd.success)
        #expect(networkd.commands.contains { $0.contains("90-barkvisor-eth0.network") })
        #expect(networkd.commands.contains { $0.contains("networkctl reapply eth0") || $0.contains("networkctl reload") })
    }

    @Test func `revert restores NM slave and networkd port L3`() {
        let nm = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .revert, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(backend: .networkManager, owned: true, createdBridge: false, ready: true),
        )
        #expect(nm.success)
        #expect(nm.commands.contains { $0.contains("nmcli connection delete barkvisor-br0-eth0") })
        #expect(nm.commands.contains { $0.contains("nmcli device reapply eth0") })
        #expect(!nm.commands.contains { $0.contains("ip link del") })
        let networkd = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .revert, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(backend: .systemdNetworkd, owned: true, createdBridge: false, ready: true),
        )
        #expect(networkd.success)
        #expect(networkd.commands.contains { $0.contains("90-barkvisor-eth0.network") })
        #expect(networkd.commands.contains { $0.contains("networkctl reapply eth0") })
        #expect(!networkd.commands.contains { $0.contains("ip link del") })
    }

    @Test func `foreign revert never ip link dels`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .revert, confirm: true),
            probe: probe(owned: true, createdBridge: false),
        )
        #expect(result.success)
        #expect(!result.commands.contains { $0.contains("ip link del") })
        #expect(result.changes.contains { $0.contains("Leave br0") || $0.contains("never default-deleted") })
        let denied = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .delete, confirm: true),
            probe: probe(owned: true, createdBridge: false),
        )
        #expect(denied.refused)
        #expect(denied.message.contains("foreign"))
        #expect(!denied.commands.contains { $0.contains("ip link del") })
    }

    @Test func `delete refuses when Workloads still reference the bridge`() {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(
                action: .delete,
                bridge: "br1",
                nic: "eth1",
                confirm: true,
                attachedWorkloadCount: 2,
            ),
            probe: probe(owned: true, createdBridge: true, nic: "eth1"),
        )
        #expect(result.refused)
        #expect(result.conflict)
        #expect(result.message.contains("Workload"))
        #expect(!result.commands.contains { $0.contains("ip link del") })
    }

    @Test func `createdBridgeForUplink reads marker uplink`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try LinuxHostBridgeApply.writeOwnerMarker(
            bridge: "br1",
            uplink: "en0",
            createdBridge: true,
            dataDir: dir,
        )
        #expect(LinuxHostBridgeApply.createdBridgeForUplink("en0", dataDir: dir))
        #expect(!LinuxHostBridgeApply.createdBridgeForUplink("eth0", dataDir: dir))
    }

    @Test func `delete without confirm is a preview`() throws {
        let preview = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .delete, bridge: "br0", nic: "eth0"),
            probe: probe(owned: true, createdBridge: true, ready: true),
        )
        #expect(preview.success)
        #expect(preview.needsConfirm)
        #expect(!preview.applied)
        #expect(preview.commands.contains { $0.contains("ip link delete br0 type bridge") })
        let recorder = RecordingLinuxHostBridgeMutator()
        let live = try LinuxHostBridgeApplyLive.run(
            request: LinuxHostBridgeApplyRequest(action: .delete, bridge: "br0", nic: "eth0"),
            probe: probe(owned: true, createdBridge: true, ready: true),
            mutator: recorder,
        )
        #expect(live.needsConfirm)
        #expect(!live.applied)
        #expect(recorder.steps.isEmpty)
    }

    @Test func `live delete is immediate without keep window`() throws {
        let recorder = RecordingLinuxHostBridgeMutator()
        let result = try LinuxHostBridgeApplyLive.run(
            request: LinuxHostBridgeApplyRequest(action: .delete, nic: "eth0", confirm: true),
            probe: probe(owned: true, createdBridge: true, ready: true),
            mutator: recorder,
        )
        #expect(result.applied)
        #expect(!result.pendingCommit)
        #expect(recorder.steps.contains { $0.contains("action=delete") })
        #expect(recorder.steps.contains { $0.contains("ip link delete") || $0.contains("Delete br0") })
    }
}
