import Foundation
import Testing
@testable import BarkVisorCore

@Suite("HostInventory")
struct HostInventoryTests {
    private static let testHostId = "11111111-1111-1111-1111-111111111111"

    private func snapshot(version: String = Config.version) -> HostInventory {
        HostInventoryService.snapshot(version: version, hostId: Self.testHostId)
    }

    @Test func `snapshot has schema version one`() {
        let inv = snapshot()
        #expect(inv.schemaVersion == 1)
        #expect(inv.schemaVersion == HostInventoryService.currentSchemaVersion)
    }

    @Test func `snapshot includes durable host id`() {
        let inv = snapshot()
        #expect(inv.hostId == Self.testHostId)
        #expect(UUID(uuidString: inv.hostId) != nil)
    }

    @Test func `snapshot matches platform capabilities`() {
        let inv = snapshot()
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

    @Test func `snapshot resources match platform host`() {
        let inv = snapshot()
        #expect(inv.resources.cpuCount == PlatformHost.cpuCount)
        #expect(inv.resources.memoryTotalMB == PlatformHost.physicalMemoryMB)
        #expect(inv.platform.os == PlatformHost.platformName)
        #expect(!inv.platform.hostname.isEmpty)
        #expect(inv.displayName == inv.platform.hostname)
    }

    @Test func `snapshot includes guest types and agent`() {
        let inv = snapshot(version: "1.2.3-test")
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
        let inv = snapshot()
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(HostInventory.self, from: data)
        #expect(decoded == inv)
        #expect(decoded.hostId == Self.testHostId)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["hostId"] as? String == Self.testHostId)
    }

    @Test func `snapshot persists host id under data dir`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "host-inv-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = HostInventoryService.snapshot(dataDir: dir)
        let second = HostInventoryService.snapshot(dataDir: dir)
        #expect(first.hostId == second.hostId)
        #expect(UUID(uuidString: first.hostId) != nil)

        let stored = try String(
            contentsOf: HostIdentity.fileURL(in: dir), encoding: .utf8,
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stored == first.hostId)
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
            #expect(snapshot().virtualization.features.kvmDevice == kvm)
        #else
            #expect(HostInventoryService.kvmDevicePresent() == false)
            #expect(snapshot().virtualization.features.kvmDevice == false)
        #endif
    }
}
