import Foundation
import Testing

@testable import BarkVisorCore

@Suite("HostInventory")
struct HostInventoryTests {
    @Test func snapshotHasSchemaVersionOne() {
        let inv = HostInventoryService.snapshot()
        #expect(inv.schemaVersion == 1)
        #expect(inv.schemaVersion == HostInventoryService.currentSchemaVersion)
    }

    @Test func snapshotMatchesPlatformCapabilities() {
        let inv = HostInventoryService.snapshot()
        #expect(inv.platform.arch == PlatformCapabilities.hostArch)
        #expect(inv.virtualization.accelerator == PlatformCapabilities.accelerator)
        #expect(inv.virtualization.qemuCPUModel == PlatformCapabilities.qemuCPUModel)
        #expect(inv.virtualization.defaultGuestArch == PlatformCapabilities.defaultGuestArch)
        #expect(
            inv.virtualization.features.bridgedNetworking
                == PlatformCapabilities.supportsBridgedNetworking,
        )
        #expect(
            inv.virtualization.features.managedBridgeDaemon
                == PlatformCapabilities.supportsManagedBridgeDaemon,
        )
        #expect(
            inv.virtualization.features.usbPassthrough
                == PlatformCapabilities.supportsUSBPassthrough,
        )
        #expect(
            inv.virtualization.features.inAppUpdate == PlatformCapabilities.supportsInAppUpdate,
        )
    }

    @Test func snapshotResourcesMatchPlatformHost() {
        let inv = HostInventoryService.snapshot()
        #expect(inv.resources.cpuCount == PlatformHost.cpuCount)
        #expect(inv.resources.memoryTotalMB == PlatformHost.physicalMemoryMB)
        #expect(inv.platform.os == PlatformHost.platformName)
        #expect(!inv.platform.hostname.isEmpty)
        #expect(inv.displayName == inv.platform.hostname)
    }

    @Test func snapshotIncludesGuestTypesAndAgent() {
        let inv = HostInventoryService.snapshot(version: "1.2.3-test")
        #expect(inv.agent.role == "colocal")
        #expect(inv.agent.version == "1.2.3-test")
        #expect(inv.agent.apiVersion == 1)
        #expect(inv.guestTypes.count == GuestProfiles.all.count)
        #expect(!inv.collectedAt.isEmpty)
        #expect(inv.storage.contains { $0.kind == "dataDir" })
    }

    @Test func inventoryCodableRoundTrip() throws {
        let inv = HostInventoryService.snapshot()
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(HostInventory.self, from: data)
        #expect(decoded == inv)
    }

    @Test func kvmProbeConsistentWithAcceleratorOnLinux() {
        #if os(Linux)
            let kvm = HostInventoryService.kvmDevicePresent()
            let accel = PlatformCapabilities.accelerator
            if kvm {
                #expect(accel == "kvm")
            } else {
                #expect(accel == "tcg")
            }
            #expect(HostInventoryService.snapshot().virtualization.features.kvmDevice == kvm)
        #else
            #expect(HostInventoryService.kvmDevicePresent() == false)
            #expect(HostInventoryService.snapshot().virtualization.features.kvmDevice == false)
        #endif
    }
}
