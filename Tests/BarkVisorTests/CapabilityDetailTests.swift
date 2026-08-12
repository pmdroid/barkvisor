import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("CapabilityDetail (PAS-94)")
struct CapabilityDetailTests {
    @Test func `builder emits one row per projected feature`() {
        let details = CapabilityDetailBuilder.from(inventory: linuxInventory())
        #expect(details.map(\.code) == CapabilityDetailBuilder.projectedFeatures.map(\.rawValue))
        #expect(Set(details.map(\.code)).count == CapabilityDetailBuilder.projectedFeatures.count)
    }

    @Test func `linux reason codes for os-managed features`() {
        let inv = linuxInventory()
        let managed = CapabilityDetailBuilder.detail(for: .managedBridgeDaemon, inventory: inv)
        #expect(!managed.supported)
        #expect(managed.reasonCode == CapabilityReasonCode.linuxOsManaged.rawValue)
        #expect(managed.remediation?.isEmpty == false)

        let update = CapabilityDetailBuilder.detail(for: .inAppUpdate, inventory: inv)
        #expect(!update.supported)
        #expect(update.reasonCode == CapabilityReasonCode.linuxPkgUpdate.rawValue)
        #expect(update.remediation?.localizedCaseInsensitiveContains("package manager") == true)
    }

    @Test func `unsupported bridged networking on linux uses helper_missing`() {
        let helperMissing = false
        let base = linuxInventory().virtualization.features
        let features = VirtualizationFeatures(
            bridgedNetworking: HostInventoryService.bridgedNetworkingSupported(
                platformSupports: true,
                qemuBridgeHelper: helperMissing,
                os: "Linux",
            ),
            managedBridgeDaemon: base.managedBridgeDaemon,
            usbPassthrough: base.usbPassthrough,
            inAppUpdate: base.inAppUpdate,
            kvmDevice: base.kvmDevice,
            qemuBridgeHelper: helperMissing,
        )
        #expect(!features.bridgedNetworking)
        let inv = makeInventory(os: "Linux", arch: "x86_64", accelerator: "kvm", features: features)
        let bridged = CapabilityDetailBuilder.detail(for: .bridgedNetworking, inventory: inv)
        #expect(!bridged.supported)
        #expect(bridged.reasonCode == CapabilityReasonCode.helperMissing.rawValue)
        #expect(bridged.remediation?.contains("qemu-bridge-helper") == true)
    }

    @Test func `macos host marks updates supported and kvm-unrelated features without reason`() {
        let inv = macOSInventory()
        let update = CapabilityDetailBuilder.detail(for: .inAppUpdate, inventory: inv)
        #expect(update.supported)
        #expect(update.reasonCode == nil)
        #expect(update.remediation == nil)

        let usb = CapabilityDetailBuilder.detail(for: .usbPassthrough, inventory: inv)
        #expect(usb.supported)
        #expect(usb.reasonCode == nil)
    }

    @Test func `unsupported usb uses os_unsupported`() {
        let inv = makeInventory(
            os: "unknown",
            arch: "x86_64",
            accelerator: "tcg",
            features: VirtualizationFeatures(
                bridgedNetworking: false,
                managedBridgeDaemon: false,
                usbPassthrough: false,
                inAppUpdate: false,
                kvmDevice: false,
                qemuBridgeHelper: false,
            ),
        )
        let usb = CapabilityDetailBuilder.detail(for: .usbPassthrough, inventory: inv)
        #expect(!usb.supported)
        #expect(usb.reasonCode == CapabilityReasonCode.osUnsupported.rawValue)
        #expect(usb.remediation?.isEmpty == false)
    }

    @Test func `currentCapabilities projects details matching booleans`() {
        let caps = SystemCapabilitiesController.currentCapabilities()
        #expect(caps.details.count == CapabilityDetailBuilder.projectedFeatures.count)

        let byCode = Dictionary(uniqueKeysWithValues: caps.details.map { ($0.code, $0) })
        #expect(byCode["bridgedNetworking"]?.supported == caps.supportsBridgedNetworking)
        #expect(byCode["managedBridgeDaemon"]?.supported == caps.supportsManagedBridgeDaemon)
        #expect(byCode["usbPassthrough"]?.supported == caps.supportsUSBPassthrough)
        #expect(byCode["inAppUpdate"]?.supported == caps.supportsInAppUpdate)

        #if os(Linux)
            #expect(byCode["managedBridgeDaemon"]?.supported == false)
            #expect(byCode["managedBridgeDaemon"]?.reasonCode == CapabilityReasonCode.linuxOsManaged.rawValue)
            #expect(byCode["inAppUpdate"]?.supported == false)
            #expect(byCode["inAppUpdate"]?.reasonCode == CapabilityReasonCode.linuxPkgUpdate.rawValue)
            let helperPresent = HostInventoryService.qemuBridgeHelperPresent()
            #expect(byCode["bridgedNetworking"]?.supported == helperPresent)
            if !helperPresent {
                #expect(byCode["bridgedNetworking"]?.reasonCode == CapabilityReasonCode.helperMissing.rawValue)
                #expect(byCode["bridgedNetworking"]?.remediation?.contains("qemu-bridge-helper") == true)
            }
        #elseif os(macOS)
            #expect(byCode["managedBridgeDaemon"]?.supported == true)
            #expect(byCode["inAppUpdate"]?.supported == true)
            #expect(byCode["bridgedNetworking"]?.supported == true)
        #endif
    }

    @Test func `capability detail is json-codable`() throws {
        let row = CapabilityDetail(
            code: .inAppUpdate,
            supported: false,
            reason: .linuxPkgUpdate,
            remediation: "Use the package manager.",
        )
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(CapabilityDetail.self, from: data)
        #expect(decoded == row)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["code"] as? String == "inAppUpdate")
        #expect(object?["reasonCode"] as? String == "linux_pkg_update")
    }

    @Test func `unsupported feature error uses 422 and snake_case code`() {
        let err = BarkVisorError.unsupportedFeature(.bridgedNetworking)
        #expect(err.code == "bridged_networking")
        #expect(err.httpStatus == 422)
        #expect(err.errorDescription == PlatformCapabilities.unsupportedMessage(.bridgedNetworking))

        #expect(PlatformCapabilities.Feature.inAppUpdate.errorCode == "in_app_update")
        #expect(PlatformCapabilities.Feature.usbPassthrough.errorCode == "usb_passthrough")
        #expect(PlatformCapabilities.Feature.managedBridgeDaemon.errorCode == "managed_bridge_daemon")
    }

    @Test func `requireBridgedNetworking matches capabilities product flag`() {
        let advertised = HostInventoryService.snapshot().virtualization.features.bridgedNetworking
        if advertised {
            #expect(throws: Never.self) {
                try PlatformCapabilities.requireBridgedNetworking()
            }
        } else {
            let err = #expect(throws: BarkVisorError.self) {
                try PlatformCapabilities.requireBridgedNetworking()
            }
            #expect(err?.code == "bridged_networking")
            #expect(err?.httpStatus == 422)
        }
    }
}

// MARK: - Fixtures

private func linuxInventory() -> HostInventory {
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

private func macOSInventory() -> HostInventory {
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
