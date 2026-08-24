import Foundation
import Testing
@testable import BarkVisorCore

@Suite("NetworkCapability (PAS-57 / PAS-67)")
struct NetworkCapabilityTests {
    @Test func `modes are nat bridged isolated — tailnet deferred`() {
        #expect(NetworkCapability.modes == ["nat", "bridged", "isolated"])
        #expect(NetworkMode(rawValue: "tailnet") == nil)
        #expect(NetworkMode(rawValue: "none") == nil)
    }

    @Test func `requireMode rejects unknown modes`() {
        let err = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requireMode("tailnet")
        }
        #expect(err?.httpStatus == 400)
        #expect(err?.code == "bad_request")
        #expect(err?.errorDescription?.contains("isolated") == true)
    }

    @Test func `requireMode nat and isolated always succeed`() {
        #expect(throws: Never.self) {
            try NetworkCapability.requireMode("nat")
        }
        #expect(throws: Never.self) {
            try NetworkCapability.requireMode("isolated")
        }
    }

    @Test func `missing network is implicit NAT`() throws {
        #expect(try NetworkCapability.effectiveMode(of: nil) == .nat)
    }

    @Test func `port forwards require NAT`() {
        #expect(throws: Never.self) {
            try NetworkCapability.requirePortForwardsAllowed(count: 1, mode: .nat)
        }
        let isolated = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requirePortForwardsAllowed(count: 1, mode: .isolated)
        }
        #expect(isolated?.httpStatus == 400)
        #expect(isolated?.code == "invalid_port_forward")
        let bridged = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requirePortForwardsAllowed(count: 1, mode: .bridged)
        }
        #expect(bridged?.httpStatus == 400)
        #expect(bridged?.code == "invalid_port_forward")
        #expect(throws: Never.self) {
            try NetworkCapability.requirePortForwardsAllowed(count: 0, mode: .isolated)
        }
    }

    @Test func `requireBridgedInterface missing host iface is 422`() {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard advertised else { return }
        let err = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requireBridgedInterface("bv-missing-if")
        }
        #expect(err?.code == "interface_missing")
        #expect(err?.httpStatus == 422)
        #expect(err?.errorDescription?.contains("does not exist") == true)
    }

    @Test func `requireBridgedInterface rejects fake vmnet name`() {
        #expect(!HostInfoService.interfaceExists("vmnet"))
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard advertised else { return }
        let err = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requireBridgedInterface("vmnet")
        }
        #expect(err?.code == "interface_missing")
        #expect(err?.httpStatus == 422)
    }

    @Test func `requireBridgedInterface invalid name is invalid_bridge`() {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard advertised else { return }
        let err = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requireBridgedInterface("bad name!")
        }
        #expect(err?.code == "invalid_bridge")
        #expect(err?.httpStatus == 400)
    }

    @Test func `requireBridgedInterface existing loopback when advertised`() throws {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        guard advertised else { return }
        #if os(macOS)
            let iface = "lo0"
        #else
            let iface = "lo"
        #endif
        guard HostInfoService.interfaceExists(iface) else { return }
        #if os(Linux)
            if !LinuxHostNetwork.bridgeACLPermits(iface) {
                let err = #expect(throws: BarkVisorError.self) {
                    try NetworkCapability.requireBridgedInterface(iface)
                }
                #expect(err?.code == "bridge_acl")
                #expect(err?.httpStatus == 422)
                return
            }
        #endif
        try NetworkCapability.requireBridgedInterface(iface)
    }

    @Test func `bridge ACL parser allow all and named entries`() throws {
        #expect(LinuxHostNetwork.bridgeACLAllows("br0", fileContents: "allow br0\n"))
        #expect(LinuxHostNetwork.bridgeACLAllows("br0", fileContents: "# comment\nallow all\n"))
        #expect(!LinuxHostNetwork.bridgeACLAllows("br0", fileContents: "allow virbr0 # other\n"))
        #expect(!LinuxHostNetwork.bridgeACLAllows("br0", fileContents: ""))
        #expect(!LinuxHostNetwork.bridgeACLAllows("", fileContents: "allow all"))
        let missing = LinuxHostNetwork.bridgeACLDecision("br0", at: "/no/such/qemu-bridge.conf")
        #expect(missing == nil)
        #expect(!LinuxHostNetwork.bridgeACLPermits("br0", at: "/no/such/qemu-bridge.conf"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("bridge.conf").path
        try "allow br0\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(LinuxHostNetwork.bridgeACLDecision("br0", at: path) == true)
        #expect(LinuxHostNetwork.bridgeACLDecision("docker0", at: path) == false)
    }

    @Test func `networkModes projects nat always and bridged from inventory`() {
        let linux = HostInventory(
            schemaVersion: 1,
            hostId: "test-host-id",
            displayName: "test",
            agent: AgentInfo(version: "test"),
            platform: PlatformInfo(os: "Linux", osVersion: "t", arch: "x86_64", hostname: "t"),
            resources: ResourcesInfo(cpuCount: 2, memoryTotalMB: 1_024, memoryUsedMB: 1, cpuLoadPercent: 0),
            storage: [],
            networking: NetworkingInfo(interfaces: []),
            virtualization: VirtualizationInfo(
                accelerator: "kvm",
                qemuCPUModel: "host",
                defaultGuestArch: "x86_64",
                features: VirtualizationFeatures(
                    bridgedNetworking: false,
                    managedBridgeDaemon: false,
                    usbPassthrough: true,
                    inAppUpdate: false,
                    kvmDevice: true,
                    qemuBridgeHelper: false,
                ),
            ),
            guestTypes: [],
            collectedAt: "2026-08-12T00:00:00Z",
        )
        let modes = CapabilityDetailBuilder.networkModes(from: linux)
        #expect(modes.map(\.mode) == NetworkCapability.modes)
        #expect(modes[0].supported)
        #expect(!modes[1].supported)
        #expect(modes[1].reasonCode == CapabilityReasonCode.helperMissing.rawValue)
        #expect(modes[1].remediation?.contains("qemu-bridge-helper") == true)
        #expect(modes[2].mode == "isolated")
        #expect(modes[2].supported)
        #expect(modes[2].label == NetworkMode.isolated.label)
    }
}
