import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct QEMUBuilderValidationTests {
    // MARK: - IPv4 Validation

    @Test func `valid I pv 4`() {
        #expect(throws: Never.self) { try validateIPv4("192.168.1.1") }
        #expect(throws: Never.self) { try validateIPv4("0.0.0.0") }
        #expect(throws: Never.self) { try validateIPv4("255.255.255.255") }
        #expect(throws: Never.self) { try validateIPv4("10.0.0.1") }
        #expect(throws: Never.self) { try validateIPv4("172.16.0.1") }
    }

    @Test func `invalid I pv 4`() {
        #expect(throws: (any Error).self) { try validateIPv4("256.0.0.0") }
        #expect(throws: (any Error).self) { try validateIPv4("1.2.3") }
        #expect(throws: (any Error).self) { try validateIPv4("1.2.3.4.5") }
        #expect(throws: (any Error).self) { try validateIPv4("01.02.03.04") } // leading zeros
        #expect(throws: (any Error).self) { try validateIPv4("abc.def.ghi.jkl") }
        #expect(throws: (any Error).self) { try validateIPv4("") }
    }

    // MARK: - Port Validation

    @Test func `valid port`() {
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(1) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(80) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(443) }
        #expect(throws: Never.self) { try QEMUBuilder.validatePort(65_535) }
    }

    @Test func `invalid port`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(0) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(-1) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(65_536) }
        #expect(throws: (any Error).self) { try QEMUBuilder.validatePort(100_000) }
    }

    // MARK: - Protocol Validation

    @Test func `valid protocol`() {
        #expect(throws: Never.self) { try QEMUBuilder.validateProtocol("tcp") }
        #expect(throws: Never.self) { try QEMUBuilder.validateProtocol("udp") }
    }

    @Test func `invalid protocol`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("icmp") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("TCP") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateProtocol("http") }
    }

    // MARK: - Resolution Validation

    @Test func `valid resolution`() throws {
        let (w, h) = try QEMUBuilder.validateResolution("1280x800")
        #expect(w == "1280")
        #expect(h == "800")

        let (w2, h2) = try QEMUBuilder.validateResolution("1920x1080")
        #expect(w2 == "1920")
        #expect(h2 == "1080")

        let (w3, h3) = try QEMUBuilder.validateResolution("7680x4320")
        #expect(w3 == "7680")
        #expect(h3 == "4320")
    }

    @Test func `invalid resolution`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("0x0") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("9999x9999") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("abc") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("1280x") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("x800") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateResolution("") }
    }

    // MARK: - Network modes (PAS-67)

    private func netSpec(
        mode: String?,
        forwards: [WorkloadPortForward] = [],
    ) -> WorkloadSpec {
        WorkloadSpec(
            metadata: WorkloadMetadata(name: "net-test"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: min(2, max(1, PlatformHost.cpuCount)), memoryMb: 512),
                networks: [WorkloadNetwork(mode: mode, portForwards: forwards)],
            ),
        )
    }

    @Test func `implicit NAT is user slirp`() throws {
        let (args, wrap) = try QEMUBuilder.networkArgs(spec: netSpec(mode: nil), network: nil)
        #expect(!wrap)
        #expect(args.contains("-netdev"))
        #expect(args.contains { $0.hasPrefix("user,id=net0") && !$0.contains("restrict=on") })
    }

    @Test func `isolated is restrict-on slirp`() throws {
        let net = Network(
            id: "iso-1", name: "Private", mode: "isolated",
            bridge: nil, macAddress: nil, dnsServer: nil,
            autoCreated: false, isDefault: false,
        )
        let (args, wrap) = try QEMUBuilder.networkArgs(spec: netSpec(mode: "isolated"), network: net)
        #expect(!wrap)
        #expect(args.contains { $0 == "user,id=net0,restrict=on" })
    }

    @Test func `hostfwd on isolated is 400`() {
        let net = Network(
            id: "iso-1", name: "Private", mode: "isolated",
            bridge: nil, macAddress: nil, dnsServer: nil,
            autoCreated: false, isDefault: false,
        )
        let spec = netSpec(
            mode: "isolated",
            forwards: [WorkloadPortForward(hostPort: 8_080, guestPort: 80, proto: "tcp")],
        )
        let err = #expect(throws: BarkVisorError.self) {
            _ = try QEMUBuilder.networkArgs(spec: spec, network: net)
        }
        #expect(err?.httpStatus == 400)
        #expect(err?.code == "invalid_port_forward")
    }

    @Test func `hostfwd on implicit NAT is applied`() throws {
        let spec = netSpec(
            mode: "nat",
            forwards: [WorkloadPortForward(hostPort: 8_080, guestPort: 80, proto: "tcp")],
        )
        let (args, _) = try QEMUBuilder.networkArgs(spec: spec, network: nil)
        #expect(args.contains { $0.contains("hostfwd=tcp::8080-:80") })
    }

    // MARK: - MAC Address Validation

    @Test func `valid MAC`() {
        #expect(throws: Never.self) { try validateMAC("52:54:00:12:34:56") }
        #expect(throws: Never.self) { try validateMAC("aa:bb:cc:dd:ee:ff") }
        #expect(throws: Never.self) { try validateMAC("AA:BB:CC:DD:EE:FF") }
    }

    @Test func `invalid MAC`() {
        #expect(throws: (any Error).self) { try validateMAC("52:54:00:12:34") } // too few
        #expect(throws: (any Error).self) { try validateMAC("52:54:00:12:34:56:78") } // too many
        #expect(throws: (any Error).self) { try validateMAC("52:54:00:12:34:GG") } // non-hex
        #expect(throws: (any Error).self) { try validateMAC("52-54-00-12-34-56") } // wrong separator
        #expect(throws: (any Error).self) { try validateMAC("") } // empty
        #expect(throws: (any Error).self) { try validateMAC("5254.0012.3456") } // dot notation
    }

    // MARK: - Shared Path Validation

    @Test func `shared path rejects commas`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateSharedPath("/Users/test/path,with,commas") }
    }

    @Test func `shared path rejects outside allowed prefixes`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.validateSharedPath("/etc/passwd") }
        #expect(throws: (any Error).self) { try QEMUBuilder.validateSharedPath("/tmp/something") }
    }

    @Test func `shared path rejects non existent path`() {
        #expect(throws: (any Error).self) {
            try QEMUBuilder.validateSharedPath(
                NSHomeDirectory() + "/nonexistent_path_\(UUID().uuidString)",
            )
        }
    }

    @Test func `shared path accepts home directory`() {
        // Home directory itself should be valid (it exists and is within allowed prefix)
        #expect(throws: Never.self) { try QEMUBuilder.validateSharedPath(NSHomeDirectory()) }
    }

    // MARK: - VM Type

    @Test func `unknown VM type throws`() {
        #expect(throws: (any Error).self) { try QEMUBuilder.binary(for: "freebsd") }
        #expect(throws: (any Error).self) { try QEMUBuilder.binary(for: "") }
        #expect(throws: (any Error).self) { try QEMUBuilder.binary(for: "windows-amd64") }
    }

    @Test func `binary name is arch aware`() throws {
        #expect(try QEMUBuilder.binaryName(for: "linux-arm64") == "qemu-system-aarch64")
        #expect(try QEMUBuilder.binaryName(for: "windows-arm64") == "qemu-system-aarch64")
        #expect(try QEMUBuilder.binaryName(for: "linux-amd64") == "qemu-system-x86_64")
        #expect(try QEMUBuilder.binaryName(for: "linux-x86_64") == "qemu-system-x86_64")
    }

    @Test func `machine type is arch aware`() {
        #expect(QEMUBuilder.machineType(for: "linux-arm64") == "virt")
        #expect(QEMUBuilder.machineType(for: "windows-arm64") == "virt")
        #expect(QEMUBuilder.machineType(for: "linux-amd64") == "q35")
        #expect(QEMUBuilder.machineType(for: "linux-x86_64") == "q35")
    }

    @Test func `accelerator is host platform specific`() {
        #if os(macOS)
            #expect(QEMUBuilder.accelerator == "hvf")
            #expect(QEMUBuilder.cpuModel == "host")
        #elseif os(Linux)
            // KVM when /dev/kvm exists; TCG fallback (e.g. Orb without nested virt).
            let accel = QEMUBuilder.accelerator
            #expect(accel == "kvm" || accel == "tcg")
            if accel == "kvm" {
                #expect(QEMUBuilder.cpuModel == "host")
            } else {
                #expect(QEMUBuilder.cpuModel == "max")
            }
        #endif
        // QEMUBuilder and PlatformCapabilities must agree (capabilities API + launch args).
        #expect(QEMUBuilder.accelerator == PlatformCapabilities.accelerator)
        #expect(QEMUBuilder.cpuModel == PlatformCapabilities.qemuCPUModel)
        let native = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        #expect(WorkloadBackendProjector.project(guestType: native).accelerator == QEMUBuilder.accelerator)
    }

    // MARK: - Firmware

    @Test func `firmwareArgs omits pflash when UEFI is disabled`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(id: "vm-uefi-off", name: "off"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 1, memoryMb: 512),
                firmware: WorkloadFirmware(uefi: false, tpm: false),
            ),
        )
        let args = try QEMUBuilder.firmwareArgs(
            spec: spec,
            vmID: "vm-uefi-off",
            vmType: "linux-arm64",
        )
        #expect(args.isEmpty)
    }
}
