import Foundation
import Testing
@testable import BarkVisorCore

struct MacHostNetworkApplyTests {
    private let hardwarePorts = """
    Hardware Port: USB 10/100/1000 LAN
    Device: en8
    Ethernet Address: 00:11:22:33:44:55

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: aa:bb:cc:dd:ee:ff

    Hardware Port: Thunderbolt Bridge
    Device: bridge0
    Ethernet Address: N/A

    VLAN Configurations
    ===================
    Hardware Port: Fake VLAN
    Device: vlan0
    """

    @Test func `listallhardwareports maps device to resolved service name`() {
        let ports = MacHostNetwork.parseHardwarePorts(hardwarePorts)
        #expect(ports.map(\.device) == ["en8", "en0", "bridge0"])
        #expect(MacHostNetwork.serviceName(forDevice: "en8", ports: ports) == "USB 10/100/1000 LAN")
        #expect(MacHostNetwork.serviceName(forDevice: "en0", ports: ports) == "Wi-Fi")
        #expect(MacHostNetwork.serviceName(forDevice: nil, ports: ports) == "USB 10/100/1000 LAN")
        #expect(MacHostNetwork.serviceName(forDevice: "en99", ports: ports) == "USB 10/100/1000 LAN")
    }

    @Test func `unknown ports fall back to Ethernet placeholder`() {
        #expect(MacHostNetwork.serviceName(forDevice: "en0", ports: []) == "Ethernet")
        #expect(MacHostNetwork.resolvedService(nil) == "Ethernet")
        #expect(MacHostNetwork.resolvedService("  ") == "Ethernet")
    }

    @Test func `device-address commands quote the resolved service not Ethernet`() {
        let commands = MacHostNetwork.deviceAddressCommands(service: "USB 10/100/1000 LAN")
        #expect(commands.contains("sudo networksetup -setdhcp \"USB 10/100/1000 LAN\""))
        #expect(commands.contains("sudo networksetup -setmanual \"USB 10/100/1000 LAN\""))
        #expect(commands.contains("Device"))
        #expect(commands.contains("DHCP or static"))
        #expect(!commands.contains("\"Ethernet\""))
        #expect(!commands.contains("cluster"))
        #expect(!commands.contains("node"))
        #expect(!commands.contains("quorum"))
    }

    @Test func `ready socket_vmnet still emits device-address remediations`() {
        let ready = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            bridges: [HostBridgeSnapshot(name: "en8", enslaved: [])],
            defaultRouteInterface: "en8",
            macSocketVmnet: true,
            hardwarePortName: "USB 10/100/1000 LAN",
        ))
        #expect(ready.ready)
        #expect(ready.remediations.map(\.id) == ["device-address"])
        #expect(ready.remediations[0].label == "Device address")
        #expect(ready.remediations[0].commands.contains("\"USB 10/100/1000 LAN\""))
        #expect(!ready.remediations[0].commands.contains("\"Ethernet\""))
        #expect(!ready.remediations.map(\.id).contains("create-bridge"))
        #expect(!ready.remediations.map(\.id).contains("allow-acl"))
    }

    @Test func `missing socket_vmnet keeps install plus device-address`() {
        let missing = HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            defaultRouteInterface: "en8",
            macSocketVmnet: true,
            hardwarePortName: "USB 10/100/1000 LAN",
        ))
        #expect(!missing.ready)
        #expect(missing.remediations.map(\.id) == ["homebrew-socket-vmnet", "device-address"])
        #expect(missing.remediations[0].commands.contains("brew install socket_vmnet"))
        #expect(missing.remediations[1].commands.contains("\"USB 10/100/1000 LAN\""))
    }

    private func facts(service: String? = "USB 10/100/1000 LAN") -> HostBridgeFacts {
        HostBridgeFactsService.assemble(from: HostBridgeFactInputs(
            bridges: [HostBridgeSnapshot(name: "en8", enslaved: [])],
            defaultRouteInterface: "en8",
            macSocketVmnet: true,
            hardwarePortName: service,
        ))
    }

    private func probe(
        service: String? = "USB 10/100/1000 LAN",
        wireless: Set<String> = [],
        marker: MacHostNetworkSnapshot? = nil,
        dataDir: URL = URL(fileURLWithPath: "/tmp/barkvisor-host-network-test"),
    ) -> MacHostBridgeApplyProbe {
        let assembled = facts(service: service)
        return MacHostBridgeApplyProbe(
            facts: assembled,
            service: service,
            wirelessServices: wireless,
            marker: marker,
            dataDir: dataDir,
        )
    }

    private final class ScriptedMacHostNetworkCommands: MacHostNetworkCommandRunning, @unchecked Sendable {
        var calls: [[String]] = []
        var getInfo = ""

        func runNetworksetup(arguments: [String]) throws -> CommandResult {
            calls.append(arguments)
            if arguments.first == "-getinfo" {
                return CommandResult(exitCode: 0, stdout: Data(getInfo.utf8), stderr: Data())
            }
            return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    @Test func `evaluate refuses Wi-Fi and missing service name`() {
        let wifi = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(action: .apply, service: "Wi-Fi"),
            probe: probe(service: "Wi-Fi", wireless: ["Wi-Fi"]),
        )
        #expect(wifi.refused)
        #expect(wifi.message.contains("Wi-Fi"))
        #expect(!wifi.message.contains("cluster"))
        #expect(!wifi.message.contains("node"))
        #expect(!wifi.message.contains("quorum"))

        let missing = MacHostNetworkApply.evaluate(
            request: MacHostBridgeApplyRequest(action: .apply),
            probe: probe(service: nil),
        )
        #expect(missing.refused)
        #expect(missing.message.contains("service name"))
    }

    @Test func `evaluate refuses static Device address without address or gateway`() {
        let noAddress = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(action: .dryRun, service: "USB 10/100/1000 LAN", addressing: .staticIP),
            probe: probe(),
        )
        #expect(noAddress.refused)
        #expect(noAddress.message.contains("Device"))
        #expect(!noAddress.message.lowercased().contains("guest static"))

        let noGateway = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(
                action: .dryRun,
                service: "USB 10/100/1000 LAN",
                addressing: .staticIP,
                address: "192.168.1.10/24",
            ),
            probe: probe(),
        )
        #expect(noGateway.refused)
        #expect(noGateway.message.contains("gateway"))
    }

    @Test func `apply dry-run emits networksetup DHCP and static Device commands`() {
        let dhcp = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(action: .dryRun, service: "USB 10/100/1000 LAN", confirm: true),
            probe: probe(),
        )
        #expect(dhcp.success)
        #expect(dhcp.commands.contains { $0.contains("networksetup -setdhcp \"USB 10/100/1000 LAN\"") })
        #expect(!dhcp.commands.joined().contains("socketVmnetApply"))

        let staticOk = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(
                action: .dryRun,
                service: "USB 10/100/1000 LAN",
                addressing: .staticIP,
                address: "192.168.1.10/24",
                gateway: "192.168.1.1",
                confirm: true,
            ),
            probe: probe(),
        )
        #expect(staticOk.success)
        #expect(staticOk.commands.contains {
            $0.contains("networksetup -setmanual \"USB 10/100/1000 LAN\" 192.168.1.10 255.255.255.0 192.168.1.1")
        })
        #expect(staticOk.changes.contains { $0.contains("not the guest") })
    }

    @Test func `revert restores marker or falls back to DHCP`() {
        let fallback = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(action: .revert, service: "USB 10/100/1000 LAN"),
            probe: probe(),
        )
        #expect(fallback.success)
        #expect(fallback.commands == ["sudo networksetup -setdhcp \"USB 10/100/1000 LAN\""])
        #expect(fallback.message.contains("DHCP"))

        let restore = MacHostBridgeApply.evaluate(
            request: MacHostBridgeApplyRequest(action: .revert, service: "USB 10/100/1000 LAN"),
            probe: probe(marker: MacHostNetworkSnapshot(
                service: "USB 10/100/1000 LAN",
                addressing: "static",
                address: "192.168.1.10/24",
                subnet: "255.255.255.0",
                gateway: "192.168.1.1",
            )),
        )
        #expect(restore.success)
        #expect(restore.commands.contains {
            $0.contains("networksetup -setmanual \"USB 10/100/1000 LAN\" 192.168.1.10 255.255.255.0 192.168.1.1")
        })
    }

    @Test func `live mutator records apply without touching the host`() throws {
        let recorder = RecordingMacHostNetworkMutator()
        let result = try MacHostBridgeApplyLive.run(
            request: MacHostBridgeApplyRequest(action: .apply, service: "USB 10/100/1000 LAN", confirm: true),
            probe: probe(),
            mutator: recorder,
        )
        #expect(result.applied)
        #expect(result.success)
        #expect(recorder.steps.contains { $0.contains("action=apply") })
        #expect(recorder.steps.contains { $0.contains("networksetup -setdhcp") })
        #expect(MacHostBridgeApply.markerDirName == "host-network")
        #expect(MacHostNetworkApply.backendName == "networksetup")
    }

    @Test func `fromGetInfo parses manual and DHCP Device profiles`() {
        let manual = MacHostNetworkSnapshot.fromGetInfo(
            """
            Manual Configuration
            IP address: 10.0.0.5
            Subnet mask: 255.255.255.0
            Router: 10.0.0.1
            """,
            service: "USB 10/100/1000 LAN",
            device: "en8",
        )
        #expect(manual.addressing == MacHostBridgeAddressing.staticIP.rawValue)
        #expect(manual.address == "10.0.0.5")
        #expect(manual.subnet == "255.255.255.0")
        #expect(manual.gateway == "10.0.0.1")

        let dhcp = MacHostNetworkSnapshot.fromGetInfo(
            """
            DHCP Configuration
            IP address: 192.168.1.20
            Subnet mask: 255.255.255.0
            Router: 192.168.1.1
            """,
            service: "USB 10/100/1000 LAN",
        )
        #expect(dhcp.addressing == MacHostBridgeAddressing.dhcp.rawValue)
        #expect(dhcp.address == "192.168.1.20")
        #expect(dhcp.gateway == "192.168.1.1")
    }

    @Test func `apply captures snapshot marker before networksetup`() throws {
        let files = MemoryMacHostNetworkMarkerStore()
        let runner = ScriptedMacHostNetworkCommands()
        runner.getInfo = """
        Manual Configuration
        IP address: 10.0.0.5
        Subnet mask: 255.255.255.0
        Router: 10.0.0.1
        """
        let dataDir = URL(fileURLWithPath: "/tmp/barkvisor-host-network-capture")
        let result = try MacHostBridgeApplyLive.run(
            request: MacHostBridgeApplyRequest(
                action: .apply,
                service: "USB 10/100/1000 LAN",
                confirm: true,
            ),
            probe: probe(dataDir: dataDir),
            mutator: MacHostNetworkFileMutator(files: files, commands: runner),
        )
        #expect(result.applied)
        let url = MacHostBridgeApply.markerURL(service: "USB 10/100/1000 LAN", dataDir: dataDir)
        let marker = try JSONDecoder().decode(
            MacHostNetworkSnapshot.self,
            from: files.readMarker(from: url) ?? Data(),
        )
        #expect(marker.addressing == "static")
        #expect(marker.address == "10.0.0.5")
        #expect(marker.gateway == "10.0.0.1")
        #expect(runner.calls.first == ["-getinfo", "USB 10/100/1000 LAN"])
        let applyAt = runner.calls.firstIndex(of: ["-setdhcp", "USB 10/100/1000 LAN"])
        #expect(applyAt == 1)
        #expect(!runner.calls.joined().contains("cluster"))
    }

    @Test func `apply does not overwrite an existing marker`() throws {
        let files = MemoryMacHostNetworkMarkerStore()
        let dataDir = URL(fileURLWithPath: "/tmp/barkvisor-host-network-keep")
        let url = MacHostBridgeApply.markerURL(service: "USB 10/100/1000 LAN", dataDir: dataDir)
        let existing = MacHostNetworkSnapshot(
            service: "USB 10/100/1000 LAN",
            addressing: "dhcp",
            address: "192.168.1.9",
        )
        try files.writeMarker(JSONEncoder().encode(existing), to: url)
        let runner = ScriptedMacHostNetworkCommands()
        runner.getInfo = """
        Manual Configuration
        IP address: 10.0.0.5
        Subnet mask: 255.255.255.0
        Router: 10.0.0.1
        """
        _ = try MacHostBridgeApplyLive.run(
            request: MacHostBridgeApplyRequest(
                action: .apply,
                service: "USB 10/100/1000 LAN",
                confirm: true,
            ),
            probe: probe(dataDir: dataDir),
            mutator: MacHostNetworkFileMutator(files: files, commands: runner),
        )
        let kept = try JSONDecoder().decode(
            MacHostNetworkSnapshot.self,
            from: files.readMarker(from: url) ?? Data(),
        )
        #expect(kept.address == "192.168.1.9")
        #expect(kept.addressing == "dhcp")
        #expect(!runner.calls.contains { $0.first == "-getinfo" })
    }

    @Test func `revert restores manual profile from marker file`() throws {
        let files = MemoryMacHostNetworkMarkerStore()
        let dataDir = URL(fileURLWithPath: "/tmp/barkvisor-host-network-revert-static")
        let url = MacHostBridgeApply.markerURL(service: "USB 10/100/1000 LAN", dataDir: dataDir)
        try files.writeMarker(
            JSONEncoder().encode(MacHostNetworkSnapshot(
                service: "USB 10/100/1000 LAN",
                addressing: "static",
                address: "10.0.0.5",
                subnet: "255.255.255.0",
                gateway: "10.0.0.1",
            )),
            to: url,
        )
        let runner = ScriptedMacHostNetworkCommands()
        let result = try MacHostBridgeApplyLive.run(
            request: MacHostBridgeApplyRequest(action: .revert, service: "USB 10/100/1000 LAN"),
            probe: probe(dataDir: dataDir),
            mutator: MacHostNetworkFileMutator(files: files, commands: runner),
        )
        #expect(result.applied)
        #expect(runner.calls == [["-setmanual", "USB 10/100/1000 LAN", "10.0.0.5", "255.255.255.0", "10.0.0.1"]])
        #expect(!files.markerExists(at: url))
    }

    @Test func `revert restores DHCP profile from marker file`() throws {
        let files = MemoryMacHostNetworkMarkerStore()
        let dataDir = URL(fileURLWithPath: "/tmp/barkvisor-host-network-revert-dhcp")
        let url = MacHostBridgeApply.markerURL(service: "USB 10/100/1000 LAN", dataDir: dataDir)
        try files.writeMarker(
            JSONEncoder().encode(MacHostNetworkSnapshot(
                service: "USB 10/100/1000 LAN",
                addressing: "dhcp",
            )),
            to: url,
        )
        let runner = ScriptedMacHostNetworkCommands()
        let result = try MacHostBridgeApplyLive.run(
            request: MacHostBridgeApplyRequest(action: .revert, service: "USB 10/100/1000 LAN"),
            probe: probe(dataDir: dataDir),
            mutator: MacHostNetworkFileMutator(files: files, commands: runner),
        )
        #expect(result.applied)
        #expect(runner.calls == [["-setdhcp", "USB 10/100/1000 LAN"]])
        #expect(!files.markerExists(at: url))
    }

    @Test func `revert without marker falls back to setdhcp`() throws {
        let files = MemoryMacHostNetworkMarkerStore()
        let runner = ScriptedMacHostNetworkCommands()
        let result = try MacHostBridgeApplyLive.run(
            request: MacHostBridgeApplyRequest(action: .revert, service: "USB 10/100/1000 LAN"),
            probe: probe(dataDir: URL(fileURLWithPath: "/tmp/barkvisor-host-network-revert-missing")),
            mutator: MacHostNetworkFileMutator(files: files, commands: runner),
        )
        #expect(result.applied)
        #expect(runner.calls == [["-setdhcp", "USB 10/100/1000 LAN"]])
        #expect(result.message.contains("Device"))
        #expect(!result.message.contains("cluster"))
        #expect(!result.message.contains("node"))
        #expect(!result.message.contains("quorum"))
    }
}
