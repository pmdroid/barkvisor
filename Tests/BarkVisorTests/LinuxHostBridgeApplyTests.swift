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
        nic: String = "eth0",
        ready: Bool = false,
        onlyUplink: Bool = false,
    ) -> LinuxHostBridgeApplyProbe {
        LinuxHostBridgeApplyProbe(
            facts: facts(ready: ready, onlyUplink: onlyUplink, nic: nic),
            backend: backend,
            wirelessNics: wireless,
            sessionRiskNics: session,
            sessionWarnings: warnings,
            owned: owned,
            existingInterfaces: ready ? [nic, "lo", "br0"] : [nic, "lo"],
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
        #expect(LinuxHostBridgeApply.commitStampPath(bridge: "br0") == "/run/barkvisor/br0-commit")
        let script = LinuxHostBridgeApply.rollbackHelperScript(bridge: "br0", dataDir: "/var/lib/barkvisor")
        #expect(script.contains("/run/barkvisor/br0-commit"))
        #expect(script.contains("then exit 0"))
        #expect(script.contains("nmcli connection delete barkvisor-br0"))
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
        #expect(pending.warnings.contains { $0.contains("Keep changes") })
        #expect(!pending.applied)

        let confirmed = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .dryRun, nic: "eth0", confirm: true),
            probe: probe(session: ["eth0"]),
        )
        #expect(confirmed.success)
        #expect(!confirmed.needsConfirm)
        #expect(confirmed.commands.contains { $0.contains("netplan try") })
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
        #expect(HostNetworkPendingCommitService.linuxPendingPath(bridge: "br1") == "/run/barkvisor/br1-pending.json")
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

    @Test func `apply create-equivalent 409 when name exists`() throws {
        let result = LinuxHostBridgeApply.evaluate(
            request: LinuxHostBridgeApplyRequest(action: .apply, bridge: "br0", nic: "eth0", confirm: true),
            probe: probe(ready: true),
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
                request: LinuxHostBridgeApplyRequest(action: .apply, bridge: "br0", nic: "eth0", confirm: true),
                probe: probe(ready: true),
                mutator: RecordingLinuxHostBridgeMutator(),
            )
            Issue.record("expected conflict")
        } catch let error as BarkVisorError {
            #expect(error.httpStatus == 409)
        }
    }

    @Test func `next-free skips sysfs and markers`() {
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
    }

    @Test func `one pending commit per Device`() {
        let br0 = HostNetworkPendingCommitService.makePending(target: "br0")
        let br1 = HostNetworkPendingCommitService.makePending(target: "br1")
        #expect(HostNetworkPendingCommitService.blockingPending(target: "br1", existing: [br0])?.target == "br0")
        #expect(HostNetworkPendingCommitService.blockingPending(target: "br0", existing: [br0]) == nil)
        let expired = HostNetworkPendingCommit(
            target: "br0",
            commitDeadline: Date().addingTimeInterval(-1),
            rollbackSeconds: 30,
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
        let mac = LinuxHostBridgeApply.resolveNames(
            bodyBridge: nil,
            bodyInterface: nil,
            pathInterface: "en0",
            linuxHost: false,
        )
        #expect(mac.bridge == HostBridgeFactsService.suggestedBridgeName)
        #expect(mac.nic == "en0")
    }

    @Test func `rollback helper is per-bridge`() {
        let script = LinuxHostBridgeApply.rollbackHelperScript(bridge: "br1", dataDir: "/var/lib/barkvisor")
        #expect(script.contains("/etc/netplan/90-barkvisor-br1.yaml"))
        #expect(script.contains("barkvisor-br1"))
        #expect(script.contains("host-bridge-br1.json"))
        #expect(script.contains("/run/barkvisor/br1-pending.json"))
        #expect(!script.contains("90-barkvisor-br0.yaml"))
    }
}
