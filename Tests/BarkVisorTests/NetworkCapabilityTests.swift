import Foundation
import Testing
@testable import BarkVisorCore

@Suite("NetworkCapability (PAS-57)")
struct NetworkCapabilityTests {
    @Test func `modes are nat and bridged only`() {
        #expect(NetworkCapability.modes == ["nat", "bridged"])
    }

    @Test func `requireMode rejects unknown modes`() {
        let err = #expect(throws: BarkVisorError.self) {
            try NetworkCapability.requireMode("isolated")
        }
        #expect(err?.httpStatus == 400)
        #expect(err?.code == "bad_request")
    }

    @Test func `requireMode nat always succeeds`() {
        #expect(throws: Never.self) {
            try NetworkCapability.requireMode("nat")
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
        try NetworkCapability.requireBridgedInterface(iface)
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
    }
}
