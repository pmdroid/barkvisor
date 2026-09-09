import Foundation
import Testing
#if canImport(WinSDK)
    import WinSDK
#endif
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
            if accel == "whpx" {
                #expect(PlatformCapabilities.qemuCPUModel == "qemu64")
            } else {
                #expect(PlatformCapabilities.qemuCPUModel == "max")
            }
        #endif
        #expect(PlatformCapabilities.cpuModel(for: "whpx") == "qemu64")
    }

    @Test func `data dir override is honored`() {
        let override = "/tmp/barkvisor-windows-data"
        let dir = PlatformPaths.dataDir(
            isInstalled: true,
            dataDirOverride: override,
        )
        #expect(dir.path == URL(fileURLWithPath: override, isDirectory: true).path)
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
        let tcg = CapabilityDetailBuilder.detail(for: .tcgOnly, inventory: inv)
        #expect(tcg.supported)
        #expect(tcg.reasonCode == CapabilityReasonCode.whpxMissing.rawValue)
        let whpx = CapabilityDetailBuilder.detail(for: .whpx, inventory: inv)
        #expect(!whpx.supported)
        #expect(whpx.reasonCode == CapabilityReasonCode.whpxMissing.rawValue)
        #expect(whpx.remediation?.localizedCaseInsensitiveContains("Hypervisor Platform") == true)
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
        #expect(kvm?.detail.localizedCaseInsensitiveContains("/dev/kvm") != true)
        let bridge = report.checks.first { $0.id == "linux-bridge" }
        #expect(bridge?.status == .skip)
        let socket = report.checks.first { $0.id == "macos-socket-vmnet" }
        #expect(socket?.status == .skip)
    }

    @Test func `doctor fails when WHPX QEMU and firmware are missing`() {
        let report = DoctorService.assemble(from: DoctorFactInputs(
            os: "Windows",
            uid: 1_000,
            qemuPath: nil,
            kvmPresent: false,
            swtpmRequired: false,
            healthOK: true,
            healthDetail: "HTTP 200",
            hostBridge: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()).readiness,
            qemuImgPath: #"C:\Program Files\qemu\qemu-img.exe"#,
            isoToolPath: #"C:\msys64\ucrt64\bin\xorriso.exe"#,
            qemuMissingDevices: [],
            whpxPresent: false,
            firmwarePath: nil,
            dataDirPath: #"C:\barkvisor"#,
            dataDirWritable: true,
            listenPort: 7_777,
            listenPortFree: false,
        ))
        let qemu = report.checks.first { $0.id == "qemu" }
        #expect(qemu?.status == .fail)
        #expect(qemu?.detail.localizedCaseInsensitiveContains("winget") == true)
        #expect(qemu?.detail.contains(#"Program Files\qemu"#) == true)
        let whpx = report.checks.first { $0.id == "whpx" }
        #expect(whpx?.status == .fail)
        #expect(whpx?.detail.localizedCaseInsensitiveContains("Hypervisor Platform") == true)
        #expect(whpx?.detail.contains("HypervisorPlatform") == true)
        #expect(whpx?.detail.localizedCaseInsensitiveContains("reboot") == true)
        let firmware = report.checks.first { $0.id == "firmware" }
        #expect(firmware?.status == .fail)
        #expect(firmware?.detail.contains("edk2-x86_64-code.fd") == true)
        #expect(firmware?.detail.contains(#"Program Files\qemu\share"#) == true)
        #expect(!report.ok)
        let text = DoctorService.renderText(report)
        #expect(!text.contains("/dev/kvm is missing"))
    }

    @Test func `doctor passes WHPX QEMU firmware data dir and listen port`() {
        let report = DoctorService.assemble(from: DoctorFactInputs(
            os: "Windows",
            uid: 1_000,
            qemuPath: #"C:\Program Files\qemu\qemu-system-x86_64.exe"#,
            kvmPresent: false,
            swtpmRequired: false,
            healthOK: true,
            healthDetail: "HTTP 200",
            hostBridge: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()).readiness,
            qemuImgPath: #"C:\Program Files\qemu\qemu-img.exe"#,
            isoToolPath: #"C:\msys64\ucrt64\bin\xorriso.exe"#,
            qemuMissingDevices: [],
            whpxPresent: true,
            firmwarePath: #"C:\Program Files\qemu\share\edk2-x86_64-code.fd"#,
            dataDirPath: #"C:\barkvisor"#,
            dataDirWritable: true,
            listenPort: 7_777,
            listenPortFree: false,
        ))
        #expect(report.checks.first { $0.id == "whpx" }?.status == .ok)
        #expect(report.checks.first { $0.id == "qemu" }?.status == .ok)
        #expect(report.checks.first { $0.id == "firmware" }?.status == .ok)
        #expect(report.checks.first { $0.id == "data-dir" }?.status == .ok)
        #expect(report.checks.first { $0.id == "listen-port" }?.status == .ok)
        #expect(report.ok)
    }

    @Test func `doctor fails unwritable data dir and busy listen port`() {
        let report = DoctorService.assemble(from: DoctorFactInputs(
            os: "Windows",
            uid: 1_000,
            qemuPath: #"C:\Program Files\qemu\qemu-system-x86_64.exe"#,
            kvmPresent: false,
            swtpmRequired: false,
            healthOK: false,
            healthDetail: "connection refused",
            hostBridge: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()).readiness,
            qemuImgPath: #"C:\Program Files\qemu\qemu-img.exe"#,
            isoToolPath: #"C:\msys64\ucrt64\bin\xorriso.exe"#,
            qemuMissingDevices: [],
            whpxPresent: true,
            firmwarePath: #"C:\Program Files\qemu\share\edk2-x86_64-code.fd"#,
            dataDirPath: #"C:\barkvisor"#,
            dataDirWritable: false,
            listenPort: 7_777,
            listenPortFree: false,
        ))
        #expect(report.checks.first { $0.id == "data-dir" }?.status == .fail)
        #expect(report.checks.first { $0.id == "data-dir" }?.detail.contains("not writable") == true)
        #expect(report.checks.first { $0.id == "listen-port" }?.status == .fail)
        #expect(report.checks.first { $0.id == "listen-port" }?.detail.contains("7777") == true)
        #expect(!report.ok)
    }

    @Test func `doctor fails when data dir is missing`() {
        let report = DoctorService.assemble(from: DoctorFactInputs(
            os: "Windows",
            uid: 1_000,
            qemuPath: #"C:\Program Files\qemu\qemu-system-x86_64.exe"#,
            kvmPresent: false,
            swtpmRequired: false,
            healthOK: true,
            healthDetail: "HTTP 200",
            hostBridge: HostBridgeFactsService.assemble(from: HostBridgeFactInputs()).readiness,
            qemuImgPath: #"C:\Program Files\qemu\qemu-img.exe"#,
            isoToolPath: #"C:\msys64\ucrt64\bin\xorriso.exe"#,
            qemuMissingDevices: [],
            whpxPresent: true,
            firmwarePath: #"C:\Program Files\qemu\share\edk2-x86_64-code.fd"#,
            dataDirPath: #"C:\barkvisor"#,
            dataDirExists: false,
            dataDirWritable: false,
            listenPort: 7_777,
            listenPortFree: true,
        ))
        let dataDir = report.checks.first { $0.id == "data-dir" }
        #expect(dataDir?.status == .fail)
        #expect(dataDir?.detail.contains("missing") == true)
        #expect(dataDir?.detail.localizedCaseInsensitiveContains("not writable") != true)
        #expect(!report.ok)
    }

    @Test func `win32 memory used is total minus available`() {
        #expect(PlatformHost.memoryUsedMB(totalBytes: 8 * 1_024 * 1_024 * 1_024, availableBytes: 3 * 1_024 * 1_024 * 1_024) == 5 * 1_024)
        #expect(PlatformHost.memoryUsedMB(totalBytes: 1_024, availableBytes: 2_048) == 0)
    }

    @Test func `win32 cpu load uses GetSystemTimes idle in kernel`() {
        let idle0: UInt64 = 1_000
        let kernel0: UInt64 = 2_000
        let user0: UInt64 = 500
        let idle1: UInt64 = 1_400
        let kernel1: UInt64 = 2_600
        let user1: UInt64 = 700
        let percent = PlatformHost.cpuLoadPercent(
            idleTicks: idle1,
            kernelTicks: kernel1,
            userTicks: user1,
            previousIdleTicks: idle0,
            previousKernelTicks: kernel0,
            previousUserTicks: user0,
        )
        #expect(percent == 50)
        #expect(PlatformHost.fileTimeUInt64(low: 1, high: 1) == (UInt64(1) << 32) | 1)
    }

    @Test func `windows adapters map friendly names and skip empty ipv4`() {
        let rows = [
            WindowsAdapterRow(
                friendlyName: "Ethernet",
                ifType: 6,
                address: "192.168.1.10",
                prefixLength: 24,
                operUp: true,
            ),
            WindowsAdapterRow(
                friendlyName: "Ethernet",
                ifType: 6,
                address: "fe80::1%12",
                prefixLength: 64,
                operUp: true,
            ),
            WindowsAdapterRow(
                friendlyName: "Wi-Fi",
                ifType: 71,
                address: "10.0.0.5",
                prefixLength: 24,
                operUp: true,
            ),
            WindowsAdapterRow(
                friendlyName: "Loopback Pseudo-Interface 1",
                ifType: HostInfoService.windowsLoopbackIfType,
                address: "127.0.0.1",
                prefixLength: 8,
                operUp: true,
            ),
            WindowsAdapterRow(
                friendlyName: "Bluetooth Network Connection",
                ifType: 6,
                address: nil,
                operUp: false,
            ),
        ]
        let ifaces = HostInfoService.listInterfaces(fromWindowsRows: rows)
        #expect(ifaces.map(\.name) == ["Ethernet", "Wi-Fi", "Loopback"])
        #expect(ifaces.first { $0.name == "Loopback" }?.ipAddress == "127.0.0.1")
        #expect(HostInfoService.interfaceExists("Ethernet", windowsRows: rows))
        #expect(HostInfoService.interfaceExists("Loopback", windowsRows: rows))
        #expect(!HostInfoService.interfaceExists("eth0", windowsRows: rows))
        let addrs = HostInfoService.listInterfaceAddresses(fromWindowsRows: rows)
        #expect(addrs.contains { $0.name == "Ethernet" && $0.ipAddress == "192.168.1.10" })
        #expect(addrs.contains { $0.name == "Ethernet" && $0.ipAddress == "fe80::1" })
        #expect(!addrs.contains { $0.ipAddress.contains("%") })
        let flags = HostInfoService.linkFlags(fromWindowsRows: rows)
        #expect(flags["Ethernet"]?.operState == "up")
        #expect(flags["Bluetooth Network Connection"]?.operState == "down")
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

    @Test func `process inspect resolves the running image on windows`() {
        #if os(Windows)
            let pid = ProcessInfo.processInfo.processIdentifier
            let path = PlatformProcess.executablePath(pid: pid)
            #expect(path != nil)
            #expect(path?.localizedCaseInsensitiveContains(".exe") == true)
            #expect(kill(pid, 0) == 0)
        #endif
    }

    @Test func `probeListen is false while a tcp socket is bound on windows`() throws {
        #if os(Windows)
            try PlatformSocket.ensureStarted()
            let sock = socket(Int32(AF_INET), PlatformSocket.stream, 0)
            #expect(sock != INVALID_SOCKET)
            defer { closesocket(sock) }
            var addr = sockaddr_in()
            addr.sin_family = ADDRESS_FAMILY(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.S_un.S_addr = INADDR_ANY
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(sock, sockPtr, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            #expect(bindResult == 0)
            var bound = sockaddr_in()
            var len = Int32(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getsockname(sock, sockPtr, &len)
                }
            }
            #expect(nameResult == 0)
            let port = Int(UInt16(bigEndian: bound.sin_port))
            #expect(port > 0)
            #expect(PortRegistry.probeListen(port: port, proto: "tcp") == false)
            #expect(PortRegistry.probeListen(port: port, proto: "udp") == true)
        #endif
    }

    @Test func `firmware candidates include qemu share next to exe`() {
        #expect(PlatformQEMU.edk2X86Candidates.contains { $0.contains("Program Files") && $0.contains("edk2-x86_64-code.fd") })
        #expect(PlatformQEMU.windowsQEMUShareDirs.contains("C:\\Program Files\\qemu\\share"))
        #if os(Windows)
            #expect(PlatformQEMU.ovmfSecureBootCandidates.contains {
                $0.contains("Program Files") && $0.contains("OVMF_CODE_4M.secboot.fd")
            })
            #expect(PlatformQEMU.ovmfSecureBootCandidates.contains {
                $0.contains("edk2-x86_64-secure-code.fd")
            })
            #expect(PlatformQEMU.ovmfSecureBootVarsCandidates.contains {
                $0.contains("Program Files") && $0.contains("OVMF_VARS_4M.fd")
            })
            #expect(PlatformQEMU.swtpmInstallHint.contains("firmware.tpm=false"))
        #endif
        #expect(!QEMUBuilder.swtpmUnixIOSupported(os: "Windows"))
        #expect(PlatformQEMU.swtpmUnixIOUnavailableMessage.contains("firmware.tpm=false"))
    }

    @Test func `win32 host metrics are populated on windows`() {
        #if os(Windows)
            #expect(PlatformHost.cpuCount >= 1)
            #expect(PlatformHost.physicalMemoryBytes > 0)
            #expect(PlatformHost.memoryUsedMB >= 0)
            #expect(PlatformHost.memoryUsedMB <= PlatformHost.physicalMemoryMB)
            #expect(PlatformHost.temperatureCelsius == nil)
            #expect(PlatformGPU.utilizationPercent() == nil)
            let ifaces = HostInfoService.listInterfaces()
            #expect(ifaces.contains { $0.ipAddress == "127.0.0.1" })
            #expect(HostInfoService.interfaceExists("Loopback"))
        #endif
    }
}
