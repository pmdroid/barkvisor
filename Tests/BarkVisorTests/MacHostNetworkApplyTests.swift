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
}
