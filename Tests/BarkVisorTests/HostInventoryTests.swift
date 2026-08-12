import Foundation
import Testing
@testable import BarkVisorCore

@Suite("HostInventory")
struct HostInventoryTests {
    @Test func `snapshot has schema version one`() {
        let inv = HostInventoryService.snapshot()
        #expect(inv.schemaVersion == 1)
        #expect(inv.schemaVersion == HostInventoryService.currentSchemaVersion)
    }

    @Test func `snapshot matches platform capabilities`() {
        let inv = HostInventoryService.snapshot()
        #expect(inv.platform.arch == PlatformCapabilities.hostArch)
        #expect(inv.virtualization.accelerator == PlatformCapabilities.accelerator)
        #expect(inv.virtualization.qemuCPUModel == PlatformCapabilities.qemuCPUModel)
        #expect(inv.virtualization.defaultGuestArch == PlatformCapabilities.defaultGuestArch)
        #expect(
            inv.virtualization.features.bridgedNetworking
                == HostInventoryService.bridgedNetworkingSupported(
                    platformSupports: PlatformCapabilities.supportsBridgedNetworking,
                    qemuBridgeHelper: inv.virtualization.features.qemuBridgeHelper,
                    os: inv.platform.os,
                ),
        )
        #expect(inv.virtualization.features.qemuBridgeHelper == HostInventoryService.qemuBridgeHelperPresent())
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

    @Test func `snapshot resources match platform host`() {
        let inv = HostInventoryService.snapshot()
        #expect(inv.resources.cpuCount == PlatformHost.cpuCount)
        #expect(inv.resources.memoryTotalMB == PlatformHost.physicalMemoryMB)
        #expect(inv.platform.os == PlatformHost.platformName)
        #expect(!inv.platform.hostname.isEmpty)
        #expect(inv.displayName == inv.platform.hostname)
    }

    @Test func `snapshot includes guest types and agent`() {
        let inv = HostInventoryService.snapshot(version: "1.2.3-test")
        #expect(inv.agent.role == "colocal")
        #expect(inv.agent.version == "1.2.3-test")
        #expect(inv.agent.apiVersion == 1)
        // PAS-48: only host-runnable guest profiles (not the full static table).
        let expected = GuestProfiles.profilesCompatible(withHostArch: PlatformCapabilities.hostArch)
        #expect(inv.guestTypes.count == expected.count)
        #expect(!expected.isEmpty)
        for gt in inv.guestTypes {
            #expect(PlatformCapabilities.isCompatibleGuestArch(gt.arch))
        }
        #expect(!inv.collectedAt.isEmpty)
        #expect(inv.storage.contains { $0.kind == "dataDir" })
    }

    @Test func `inventory codable round trip`() throws {
        let inv = HostInventoryService.snapshot()
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(HostInventory.self, from: data)
        #expect(decoded == inv)
    }

    @Test func `kvm probe consistent with accelerator on linux`() {
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

    @Test func `bridged product flag requires qemu-bridge-helper on linux`() {
        #expect(
            HostInventoryService.bridgedNetworkingSupported(
                platformSupports: true,
                qemuBridgeHelper: true,
                os: "Linux",
            ),
        )
        #expect(
            !HostInventoryService.bridgedNetworkingSupported(
                platformSupports: true,
                qemuBridgeHelper: false,
                os: "Linux",
            ),
        )
        #expect(
            !HostInventoryService.bridgedNetworkingSupported(
                platformSupports: false,
                qemuBridgeHelper: true,
                os: "Linux",
            ),
        )
        #expect(
            HostInventoryService.bridgedNetworkingSupported(
                platformSupports: true,
                qemuBridgeHelper: false,
                os: "macOS",
            ),
        )
        #expect(
            !HostInventoryService.bridgedNetworkingSupported(
                platformSupports: false,
                qemuBridgeHelper: false,
                os: "macOS",
            ),
        )
    }
}
