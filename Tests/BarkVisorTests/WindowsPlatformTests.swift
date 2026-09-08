import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct WindowsPlatformTests {
    @Test func `platform name is windows on windows hosts`() {
        #if os(Windows)
            #expect(PlatformHost.platformName == "Windows")
        #endif
    }

    @Test func `accelerator is whpx or tcg never unknown`() {
        #if os(Windows)
            let accel = PlatformCapabilities.accelerator
            #expect(accel == "whpx" || accel == "tcg")
            #expect(accel != "unknown")
        #endif
    }

    @Test func `data dir override is honored`() {
        let dir = PlatformPaths.dataDir(
            isInstalled: true,
            dataDirOverride: "/tmp/barkvisor-windows-data",
        )
        #expect(dir.path == "/tmp/barkvisor-windows-data")
    }

    @Test func `path list separator is semicolon on windows`() {
        #if os(Windows)
            #expect(PlatformPaths.pathListSeparator == ";")
            #expect(PlatformPaths.isAbsoluteExecutablePath(#"C:\Program Files\qemu\qemu-system-x86_64.exe"#))
            let exe = PlatformPaths.resolvedExecutablePath(
                argument: "qemu-system-x86_64.exe",
                pathEnvironment: #"C:\Program Files\qemu;C:\Windows"#,
                currentDirectory: #"C:\unused"#,
                isExecutable: { $0.contains("Program Files") && $0.hasSuffix("qemu-system-x86_64.exe") },
            )
            #expect(exe.contains("Program Files"))
        #else
            #expect(PlatformPaths.pathListSeparator == ":")
            #expect(PlatformPaths.isAbsoluteExecutablePath("/usr/bin/qemu-system-x86_64"))
            #expect(!PlatformPaths.isAbsoluteExecutablePath("qemu-system-x86_64"))
        #endif
    }

    @Test func `capability builder marks windows features os_unsupported`() {
        let inv = HostInventory(
            schemaVersion: 1,
            hostId: "test-windows-host",
            displayName: "windows-host",
            agent: AgentInfo(version: "test"),
            platform: PlatformInfo(os: "Windows", osVersion: "test", arch: "x86_64", hostname: "windows-host"),
            resources: ResourcesInfo(cpuCount: 4, memoryTotalMB: 8_192, memoryUsedMB: 0, cpuLoadPercent: 0),
            storage: [],
            networking: NetworkingInfo(interfaces: []),
            virtualization: VirtualizationInfo(
                accelerator: "tcg",
                qemuCPUModel: "max",
                defaultGuestArch: "x86_64",
                features: VirtualizationFeatures(
                    bridgedNetworking: false,
                    managedBridgeDaemon: false,
                    usbPassthrough: false,
                    inAppUpdate: false,
                    kvmDevice: false,
                    qemuBridgeHelper: false,
                ),
                vfioProbe: VFIOInventoryFacts(),
            ),
            guestTypes: [],
            collectedAt: "2026-09-07T00:00:00Z",
        )
        let bridged = CapabilityDetailBuilder.detail(for: .bridgedNetworking, inventory: inv)
        #expect(!bridged.supported)
        #expect(bridged.reasonCode == CapabilityReasonCode.osUnsupported.rawValue)
        let usb = CapabilityDetailBuilder.detail(for: .usbPassthrough, inventory: inv)
        #expect(!usb.supported)
        #expect(usb.reasonCode == CapabilityReasonCode.osUnsupported.rawValue)
        let kvm = CapabilityDetailBuilder.detail(for: .kvmDevice, inventory: inv)
        #expect(!kvm.supported)
        #expect(kvm.reasonCode == CapabilityReasonCode.osUnsupported.rawValue)
        let update = CapabilityDetailBuilder.detail(for: .inAppUpdate, inventory: inv)
        #expect(!update.supported)
        #expect(update.reasonCode == CapabilityReasonCode.osUnsupported.rawValue)
    }

    @Test func `windows privilege service does not call linux bridge acl`() async throws {
        let svc = WindowsPrivilegeService()
        #expect(!svc.isAvailable)
        let err = await #expect(throws: BarkVisorError.self) {
            try await svc.installBridge(interface: "br0")
        }
        #expect(err?.code == "bridged_networking")
        #expect(err?.httpStatus == 422)
        let states = try await svc.getAllBridgeStates()
        #expect(states.isEmpty)
        #if os(Windows)
            #expect(PrivilegeService.shared is WindowsPrivilegeService)
            #expect(!(PrivilegeService.shared is LinuxPrivilegeService))
        #endif
    }

    @Test func `doctor skips linux macos probes on windows os`() {
        let report = DoctorService.assemble(from: DoctorFactInputs(
            os: "Windows",
            uid: 1_000,
            qemuPath: nil,
            kvmPresent: false,
            hostBridge: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()).readiness,
        ))
        let kvm = report.checks.first { $0.id == "kvm" }
        #expect(kvm?.status == .skip)
        let bridge = report.checks.first { $0.id == "linux-bridge" }
        #expect(bridge?.status == .skip)
        let socket = report.checks.first { $0.id == "macos-socket-vmnet" }
        #expect(socket?.status == .skip)
    }

    @Test func `boot identity does not read proc on windows`() {
        #if os(Windows)
            #expect(DeviceBootIdentity.current() == nil)
        #endif
    }

    @Test func `gpu utilization is nil on windows`() {
        #if os(Windows)
            #expect(PlatformGPU.utilizationPercent() == nil)
        #endif
    }

    @Test func `process inspect is nil on windows`() {
        #if os(Windows)
            let pid = ProcessInfo.processInfo.processIdentifier
            #expect(PlatformProcess.arguments(pid: pid) == nil)
            #expect(PlatformProcess.executablePath(pid: pid) == nil)
        #endif
    }

    @Test func `firmware candidates include qemu share next to exe`() {
        #expect(PlatformQEMU.edk2X86Candidates.contains { $0.contains("Program Files") && $0.contains("edk2-x86_64-code.fd") })
        #expect(PlatformQEMU.windowsQEMUShareDirs.contains("C:\\Program Files\\qemu\\share"))
    }
}
