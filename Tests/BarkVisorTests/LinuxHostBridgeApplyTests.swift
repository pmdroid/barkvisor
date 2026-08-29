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
            existingInterfaces: [nic, "lo", "br0"],
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
        #expect(ok.changes.contains { $0.contains("static") })
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
        #expect(pending.warnings.contains { $0.contains("host timer") })
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

    @Test func `script refuses ifupdown wifi and delete-bridge`() throws {
        let script = Self.scriptURL()
        let ifup = try Self.runScript(script, args: ["--dry-run", "--nic", "eth0"], env: [
            "BARKVISOR_BRIDGE_BACKEND": "ifupdown",
        ])
        #expect(ifup.exitCode == 3)
        #expect(ifup.stderr.contains("refuse ifupdown"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wlan0/wireless"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wifi = try Self.runScript(script, args: ["--dry-run", "--nic", "wlan0"], env: [
            "BARKVISOR_BRIDGE_BACKEND": "netplan",
            "BARKVISOR_BRIDGE_SYSFS": dir.path,
        ])
        #expect(wifi.exitCode == 7)
        #expect(wifi.stderr.contains("Wi-Fi"))

        let del = try Self.runScript(script, args: ["--revert", "--delete-bridge"], env: [
            "BARKVISOR_BRIDGE_BACKEND": "netplan",
            "BARKVISOR_BRIDGE_OWNED": "1",
        ])
        #expect(del.exitCode == 4)
        #expect(del.stderr.contains("default-delete"))

        let dry = try Self.runScript(script, args: ["--dry-run", "--nic", "eth0", "--confirm"], env: [
            "BARKVISOR_BRIDGE_BACKEND": "netplan",
            "BARKVISOR_BRIDGE_SESSION_RISK": "0",
        ])
        #expect(dry.exitCode == 0)
        #expect(dry.stdout.contains("barkvisor:allow-br0"))
        #expect(dry.stdout.contains("netplan try"))
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

    private static func scriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/linux-bridge-apply.sh")
    }

    private static func runScript(
        _ url: URL,
        args: [String],
        env: [String: String],
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in env {
            merged[key] = value
        }
        process.environment = merged
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        )
    }
}
