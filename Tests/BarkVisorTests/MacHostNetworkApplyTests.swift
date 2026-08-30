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
    ) -> MacHostBridgeApplyProbe {
        let assembled = facts(service: service)
        return MacHostBridgeApplyProbe(
            facts: assembled,
            service: service,
            wirelessServices: wireless,
            marker: marker,
            dataDir: FileManager.default.temporaryDirectory,
        )
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
}
