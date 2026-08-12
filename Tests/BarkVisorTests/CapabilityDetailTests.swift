import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("CapabilityDetail (PAS-37)")
struct CapabilityDetailTests {
    @Test func `builder emits one row per capability code`() {
        let details = CapabilityDetailBuilder.from(inventory: linuxTCGInventory())
        #expect(details.map(\.code) == CapabilityCode.allCases)
        #expect(Set(details.map(\.code)).count == CapabilityCode.allCases.count)
    }

    @Test func `linux without kvm reports tcg and kvm_missing`() {
        let inv = linuxTCGInventory()
        #expect(inv.virtualization.accelerator == "tcg")
        #expect(!inv.virtualization.features.kvmDevice)

        let kvm = CapabilityDetailBuilder.detail(for: .kvmDevice, inventory: inv)
        #expect(!kvm.supported)
        #expect(kvm.reasonCode == CapabilityReasonCode.kvmMissing.rawValue)
        #expect(kvm.remediation?.contains("/dev/kvm") == true)

        let tcg = CapabilityDetailBuilder.detail(for: .tcgOnly, inventory: inv)
        #expect(tcg.supported)
        #expect(tcg.reasonCode == CapabilityReasonCode.kvmMissing.rawValue)
        #expect(tcg.remediation?.localizedCaseInsensitiveContains("TCG") == true)
    }

    @Test func `linux kvm host is not tcg-only`() {
        let inv = linuxKVMInventory()
        let kvm = CapabilityDetailBuilder.detail(for: .kvmDevice, inventory: inv)
        #expect(kvm.supported)
        #expect(kvm.reasonCode == nil)

        let tcg = CapabilityDetailBuilder.detail(for: .tcgOnly, inventory: inv)
        #expect(!tcg.supported)
        #expect(tcg.reasonCode == nil)
    }

    @Test func `linux reason codes for os-managed features`() {
        let inv = linuxTCGInventory()
        let managed = CapabilityDetailBuilder.detail(for: .managedBridgeDaemon, inventory: inv)
        #expect(!managed.supported)
        #expect(managed.reasonCode == CapabilityReasonCode.linuxOsManaged.rawValue)
        #expect(managed.remediation?.isEmpty == false)

        let update = CapabilityDetailBuilder.detail(for: .inAppUpdate, inventory: inv)
        #expect(!update.supported)
        #expect(update.reasonCode == CapabilityReasonCode.linuxPkgUpdate.rawValue)

        let helper = CapabilityDetailBuilder.detail(for: .qemuBridgeHelper, inventory: inv)
        #expect(!helper.supported)
        #expect(helper.reasonCode == CapabilityReasonCode.helperMissing.rawValue)
    }

    @Test func `macos hvf host marks kvm as os_unsupported`() {
        let inv = macOSHVFInventory()
        let kvm = CapabilityDetailBuilder.detail(for: .kvmDevice, inventory: inv)
        #expect(!kvm.supported)
        #expect(kvm.reasonCode == CapabilityReasonCode.osUnsupported.rawValue)

        let tcg = CapabilityDetailBuilder.detail(for: .tcgOnly, inventory: inv)
        #expect(!tcg.supported)

        let update = CapabilityDetailBuilder.detail(for: .inAppUpdate, inventory: inv)
        #expect(update.supported)
        #expect(update.reasonCode == nil)
    }

    @Test func `currentCapabilities projects details and runnable arches`() {
        let caps = SystemCapabilitiesController.currentCapabilities()
        #expect(caps.details.count == CapabilityCode.allCases.count)
        #expect(caps.inventorySchemaVersion == HostInventoryService.currentSchemaVersion)
        #expect(caps.runnableArches == [caps.hostArch])
        #expect(caps.runnableArches.count == 1)
        #expect(PlatformCapabilities.isCompatibleGuestArch(caps.runnableArches[0]))

        let byCode = Dictionary(uniqueKeysWithValues: caps.details.map { ($0.code, $0) })
        #expect(byCode[.bridgedNetworking]?.supported == caps.supportsBridgedNetworking)
        #expect(byCode[.managedBridgeDaemon]?.supported == caps.supportsManagedBridgeDaemon)
        #expect(byCode[.usbPassthrough]?.supported == caps.supportsUSBPassthrough)
        #expect(byCode[.inAppUpdate]?.supported == caps.supportsInAppUpdate)
        #expect(byCode[.tcgOnly]?.supported == (caps.accelerator == "tcg"))

        #if os(Linux)
            if caps.accelerator == "tcg" {
                #expect(byCode[.kvmDevice]?.supported == false)
                #expect(byCode[.kvmDevice]?.reasonCode == CapabilityReasonCode.kvmMissing.rawValue)
                #expect(byCode[.tcgOnly]?.reasonCode == CapabilityReasonCode.kvmMissing.rawValue)
            }
        #endif
    }

    @Test func `capability detail is json-codable`() throws {
        let row = CapabilityDetail(
            code: .kvmDevice,
            supported: false,
            reason: .kvmMissing,
            remediation: "missing",
        )
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(CapabilityDetail.self, from: data)
        #expect(decoded == row)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["code"] as? String == "kvmDevice")
        #expect(object?["reasonCode"] as? String == "kvm_missing")
    }
}

// MARK: - Fixtures

private func linuxTCGInventory() -> HostInventory {
    makeInventory(
        os: "Linux",
        arch: "x86_64",
        accelerator: "tcg",
        features: VirtualizationFeatures(
            bridgedNetworking: true,
            managedBridgeDaemon: false,
            usbPassthrough: true,
            inAppUpdate: false,
            kvmDevice: false,
            qemuBridgeHelper: false,
        ),
    )
}

private func linuxKVMInventory() -> HostInventory {
    makeInventory(
        os: "Linux",
        arch: "x86_64",
        accelerator: "kvm",
        features: VirtualizationFeatures(
            bridgedNetworking: true,
            managedBridgeDaemon: false,
            usbPassthrough: true,
            inAppUpdate: false,
            kvmDevice: true,
            qemuBridgeHelper: true,
        ),
    )
}

private func macOSHVFInventory() -> HostInventory {
    makeInventory(
        os: "macOS",
        arch: "arm64",
        accelerator: "hvf",
        features: VirtualizationFeatures(
            bridgedNetworking: true,
            managedBridgeDaemon: true,
            usbPassthrough: true,
            inAppUpdate: true,
            kvmDevice: false,
            qemuBridgeHelper: false,
        ),
    )
}

private func makeInventory(
    os: String,
    arch: String,
    accelerator: String,
    features: VirtualizationFeatures,
) -> HostInventory {
    HostInventory(
        schemaVersion: 1,
        hostId: "test-host-id",
        displayName: "test-host",
        agent: AgentInfo(version: "test"),
        platform: PlatformInfo(os: os, osVersion: "test", arch: arch, hostname: "test-host"),
        resources: ResourcesInfo(cpuCount: 4, memoryTotalMB: 8_192, memoryUsedMB: 1_024, cpuLoadPercent: 1),
        storage: [],
        networking: NetworkingInfo(interfaces: []),
        virtualization: VirtualizationInfo(
            accelerator: accelerator,
            qemuCPUModel: accelerator == "tcg" ? "max" : "host",
            defaultGuestArch: arch == "arm64" ? "aarch64" : "x86_64",
            features: features,
        ),
        guestTypes: [],
        collectedAt: "2026-08-12T00:00:00Z",
    )
}
