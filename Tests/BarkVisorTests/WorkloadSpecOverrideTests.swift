import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct WorkloadSpecOverrideTests {
    private var fixtureCPUCount: Int {
        min(2, max(1, PlatformHost.cpuCount))
    }

    private func baseSpec(
        cpu: Int? = nil,
        memoryMb: Int = 1_024,
        overrides: WorkloadOverrides? = nil,
    ) -> WorkloadSpec {
        WorkloadSpec(
            metadata: WorkloadMetadata(name: "ov"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: cpu ?? fixtureCPUCount, memoryMb: memoryMb),
                guestType: "linux-arm64",
                firmware: WorkloadFirmware(uefi: true, tpm: false),
            ),
            overrides: overrides,
        )
    }

    private func linuxCaps(kvm: Bool = true, hugepages: Bool = true) -> WorkloadSpecResolver.HostCapabilities {
        WorkloadSpecResolver.HostCapabilities(
            platform: .linux, kvmPresent: kvm, hugepagesPresent: hugepages,
        )
    }

    private func macosCaps() -> WorkloadSpecResolver.HostCapabilities {
        WorkloadSpecResolver.HostCapabilities(
            platform: .macos, kvmPresent: false, hugepagesPresent: false,
        )
    }

    @Test func `linux overlay applies only on linux hosts`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                machine: "q35",
            ),
            macos: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 2_048),
            ),
        ))
        let onLinux = WorkloadSpecResolver.resolve(spec, host: .linux)
        #expect(onLinux.spec.spec.resources.memoryMb == 4_096)
        #expect(onLinux.spec.spec.machine == "q35")
        #expect(onLinux.spec.spec.resources.cpu == fixtureCPUCount)

        let onMac = WorkloadSpecResolver.resolve(spec, host: .macos)
        #expect(onMac.spec.spec.resources.memoryMb == 2_048)
        #expect(onMac.spec.spec.machine == "virt" || onMac.spec.spec.machine == nil)
    }

    @Test func `macos overlay is ignored on linux`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            macos: WorkloadSpecOverlay(accelerator: "tcg"),
        ))
        let resolved = WorkloadSpecResolver.resolve(spec, host: .linux)
        #expect(resolved.accelerator == nil)
        #expect(resolved.spec.spec.resources.memoryMb == 1_024)
    }

    @Test func `firmware overlay deep merges`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(firmware: WorkloadFirmwareOverlay(tpm: true)),
        ))
        let merged = WorkloadSpecResolver.resolve(spec, host: .linux).spec
        #expect(merged.spec.firmware?.uefi == true)
        #expect(merged.spec.firmware?.tpm == true)
    }

    @Test func `empty overrides are a no-op`() {
        let spec = baseSpec()
        let resolved = WorkloadSpecResolver.resolve(spec, host: .linux)
        #expect(resolved.spec == spec)
        #expect(resolved.accelerator == nil)
        #expect(!resolved.hugepages)
    }

    @Test func `invalid accelerator reports field path`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(accelerator: "hvf"),
        ))
        do {
            try WorkloadSpecResolver.validate(spec, host: linuxCaps())
            Issue.record("expected accelerator validation to fail")
        } catch let error as BarkVisorError {
            #expect(error.localizedDescription.contains("overrides.linux.accelerator"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `hugepages rejected on macos overlay`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            macos: WorkloadSpecOverlay(hugepages: true),
        ))
        do {
            try WorkloadSpecResolver.validate(spec, host: macosCaps())
            Issue.record("expected hugepages validation to fail")
        } catch let error as BarkVisorError {
            #expect(error.localizedDescription.contains("overrides.macos.hugepages"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `missing hugepages device fails on linux apply`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(hugepages: true),
        ))
        do {
            try WorkloadSpecResolver.validate(spec, host: linuxCaps(hugepages: false))
            Issue.record("expected hugepages capability check to fail")
        } catch let error as BarkVisorError {
            #expect(error.localizedDescription.contains("overrides.linux.hugepages"))
            #expect(error.localizedDescription.contains("/dev/hugepages"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `linux hugepages stored but not applied on macos`() throws {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(hugepages: true),
        ))
        try WorkloadSpecResolver.validate(spec, host: macosCaps())
        let resolved = WorkloadSpecResolver.resolve(spec, host: .macos)
        #expect(!resolved.hugepages)
    }

    @Test func `resolved cpu is host-capped on the active overlay`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(cpu: PlatformHost.cpuCount + 3),
            ),
        ))
        do {
            try WorkloadSpecProjector.validate(spec)
        } catch let error as BarkVisorError {
            if WorkloadSpecResolver.HostPlatform.current == .linux {
                #expect(error.localizedDescription.contains("CPU")
                    || error.localizedDescription.contains("cpu"))
            } else {
                Issue.record("linux overlay must not host-cap on macOS: \(error)")
            }
            return
        } catch {
            Issue.record("unexpected error \(error)")
            return
        }
        if WorkloadSpecResolver.HostPlatform.current == .linux {
            Issue.record("expected host CPU cap on Linux")
        }
    }

    @Test func `overlay machine with comma is rejected`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(machine: "virt,accel=tcg"),
        ))
        let err = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecResolver.validate(spec, host: linuxCaps())
        }
        #expect(err?.httpStatus == 400)
        let text = err?.localizedDescription ?? ""
        #expect(text.contains("overrides.linux.machine"))
        #expect(text.contains("comma"))
    }

    @Test func `overlay machine outside allowed set is rejected`() {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(machine: "pc"),
        ))
        let err = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecResolver.validate(spec, host: linuxCaps())
        }
        #expect(err?.httpStatus == 400)
        let text = err?.localizedDescription ?? ""
        #expect(text.contains("overrides.linux.machine"))
        #expect(text.contains("q35"))
        #expect(text.contains("virt"))
    }

    @Test func `overlay machine allowed types are accepted`() throws {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(machine: "virt"),
            macos: WorkloadSpecOverlay(machine: "virt"),
        ))
        try WorkloadSpecResolver.validate(spec, host: linuxCaps())
        try WorkloadSpecResolver.validate(spec, host: macosCaps())
    }

    @Test func `overlay machine that does not match merged guestType is rejected`() throws {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(machine: "q35"),
        ))
        let err = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecResolver.validate(spec, host: linuxCaps())
        }
        #expect(err?.httpStatus == 400)
        #expect(err?.code == "invalid_argument")
        let text = err?.localizedDescription ?? ""
        #expect(text.contains("overrides.linux.machine"))
        #expect(text.contains("virt"))
        #expect(text.contains("linux-arm64"))
    }

    @Test func `overlay guestType rejects base machine from the other arch`() throws {
        let native = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        let nativeMachine = try GuestProfiles.require(native).machine
        let foreignMachine = nativeMachine == "virt" ? "q35" : "virt"
        let overlay = WorkloadSpecOverlay(guestType: native)
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "ov"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 1_024),
                guestType: native,
                machine: foreignMachine,
            ),
            overrides: WorkloadSpecResolver.HostPlatform.current == .linux
                ? WorkloadOverrides(linux: overlay)
                : WorkloadOverrides(macos: overlay),
        )
        let err = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecResolver.validate(spec)
        }
        #expect(err?.httpStatus == 400)
        #expect(err?.code == "invalid_argument")
        let text = err?.localizedDescription ?? ""
        #expect(text.contains("spec.machine"))
        #expect(text.contains(nativeMachine))
        #expect(text.contains(native))
        let projectorErr = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.validate(spec)
        }
        #expect(projectorErr?.code == "invalid_argument")
    }

    @Test func `argv override is rejected with field path`() {
        let json = """
        {
          "apiVersion": "barkvisor.dev/v1",
          "kind": "VirtualMachine",
          "metadata": { "name": "n" },
          "spec": { "resources": { "cpu": 1, "memoryMb": 512 }, "disks": [], "networks": [], "usb": [] },
          "overrides": { "linux": { "argv": ["-smp", "1"] } }
        }
        """
        do {
            _ = try JSONDecoder().decode(WorkloadSpec.self, from: Data(json.utf8))
            Issue.record("expected argv decode to fail")
        } catch let error as DecodingError {
            let text = String(describing: error)
            #expect(text.contains("overrides.linux.argv"))
            #expect(text.contains("argv") && text.contains("not allowed"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `unknown override key is rejected with field path`() {
        let json = """
        {
          "apiVersion": "barkvisor.dev/v1",
          "kind": "VirtualMachine",
          "metadata": { "name": "n" },
          "spec": { "resources": { "cpu": 1, "memoryMb": 512 }, "disks": [], "networks": [], "usb": [] },
          "overrides": { "macos": { "rosettaMagic": true } }
        }
        """
        do {
            _ = try JSONDecoder().decode(WorkloadSpec.self, from: Data(json.utf8))
            Issue.record("expected unknown key decode to fail")
        } catch let error as DecodingError {
            #expect(String(describing: error).contains("overrides.macos.rosettaMagic"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `apply persists overrides without baking them into columns`() throws {
        var vm = VM(
            id: "vm-ov",
            name: "ov",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: fixtureCPUCount,
            memoryMb: 1_024,
            bootDiskId: "disk-boot",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        var spec = WorkloadSpecProjector.fromVM(vm)
        spec.overrides = WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
        )
        try WorkloadSpecProjector.apply(spec, to: &vm)
        #expect(vm.memoryMb == 1_024)
        #expect(vm.decodedOverrides?.linux?.accelerator == "tcg")
        #expect(vm.decodedOverrides?.linux?.resources?.memoryMb == 4_096)

        let roundTrip = WorkloadSpecProjector.fromVM(vm)
        #expect(roundTrip.overrides?.linux?.accelerator == "tcg")
        #expect(roundTrip.spec.resources.memoryMb == 1_024)
    }

    @Test func `create params keep portable resources and store overrides`() throws {
        let spec = baseSpec(overrides: WorkloadOverrides(
            linux: WorkloadSpecOverlay(
                resources: WorkloadResourcesOverlay(memoryMb: 4_096),
                accelerator: "tcg",
            ),
        ))
        let body = CreateVMRequest(
            name: nil, vmType: nil, osFamily: nil, cpuCount: nil, memoryMB: nil,
            diskSizeGB: 20, isoId: nil, cloudImageId: nil, cloudInit: nil,
            networkId: nil, existingDiskId: nil, sharedPaths: nil,
            portForwards: nil, usbDevices: nil, gpuDevices: nil, description: nil,
            bootOrder: nil, displayResolution: nil, uefi: nil, tpmEnabled: nil,
            spec: spec,
            workloadClass: nil,
        )
        let params = try VMController.createParams(from: body)
        #expect(params.memoryMB == 1_024)
        #expect(params.overrides?.linux?.accelerator == "tcg")
        #expect(params.overrides?.linux?.resources?.memoryMb == 4_096)
    }

    @Test func `hugepages args require the mount`() {
        #expect(throws: BarkVisorError.self) {
            try QEMUBuilder.hugepagesArgs(fileExists: { _ in false })
        }
        let args = try? QEMUBuilder.hugepagesArgs(fileExists: { _ in true })
        #expect(args == ["-mem-prealloc", "-mem-path", "/dev/hugepages"])
    }

    @Test func `backend projector uses host overlay accelerator`() {
        var vm = VM(
            id: "vm-be",
            name: "be",
            vmType: GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch),
            state: "stopped",
            cpuCount: fixtureCPUCount,
            memoryMb: 1_024,
            bootDiskId: "disk-boot",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        let hostKey = WorkloadSpecResolver.HostPlatform.current == .linux ? "linux" : "macos"
        let overlay = WorkloadSpecOverlay(accelerator: "tcg")
        vm.setOverrides(
            hostKey == "linux"
                ? WorkloadOverrides(linux: overlay)
                : WorkloadOverrides(macos: overlay),
        )
        let backend = WorkloadBackendProjector.project(vm: vm)
        #expect(backend.accelerator == "tcg")
        #expect(backend.emulated)
    }

    @Test func `tcg cpu model is max`() {
        #expect(QEMUBuilder.cpuModel(for: "tcg") == "max")
        #expect(QEMUBuilder.cpuModel(for: "kvm") == "host")
        #expect(QEMUBuilder.cpuModel(for: "hvf") == "host")
    }

    @Test func `active overlay guestType is rejected when foreign to this host`() {
        let host = PlatformCapabilities.hostArch
        let native = GuestProfiles.defaultLinuxID(forImageArch: host)
        let foreign = host == "arm64" ? "linux-amd64" : "linux-arm64"
        let spec = specWithHostOverlay(portableGuest: native, overlayGuest: foreign)

        do {
            try WorkloadSpecResolver.validate(spec)
            Issue.record("expected overlay guestType \(foreign) to be rejected on \(host)")
        } catch let error as BarkVisorError {
            let text = error.localizedDescription
            #expect(text.contains("overrides."))
            #expect(text.contains("guestType"))
            #expect(text.lowercased().contains("not compatible")
                || text.lowercased().contains("cross-architecture"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `projector validate rejects foreign active overlay guestType`() {
        let host = PlatformCapabilities.hostArch
        let native = GuestProfiles.defaultLinuxID(forImageArch: host)
        let foreign = host == "arm64" ? "linux-amd64" : "linux-arm64"
        let spec = specWithHostOverlay(portableGuest: native, overlayGuest: foreign)

        do {
            try WorkloadSpecProjector.validate(spec)
            Issue.record("expected projector.validate to reject overlay guestType \(foreign)")
        } catch let error as BarkVisorError {
            let text = error.localizedDescription
            #expect(text.contains("overrides."))
            #expect(text.lowercased().contains("not compatible")
                || text.lowercased().contains("cross-architecture"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func `inactive overlay guestType may be foreign`() throws {
        let host = PlatformCapabilities.hostArch
        let native = GuestProfiles.defaultLinuxID(forImageArch: host)
        let foreign = host == "arm64" ? "linux-amd64" : "linux-arm64"
        let overlay = WorkloadSpecOverlay(guestType: foreign)
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "ov"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 1_024),
                guestType: native,
            ),
            overrides: WorkloadSpecResolver.HostPlatform.current == .linux
                ? WorkloadOverrides(macos: overlay)
                : WorkloadOverrides(linux: overlay),
        )
        try WorkloadSpecResolver.validate(spec)
        try WorkloadSpecProjector.validate(spec)
    }

    @Test func `active overlay guestType matching host is accepted`() throws {
        let native = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        let spec = specWithHostOverlay(portableGuest: native, overlayGuest: native)
        try WorkloadSpecResolver.validate(spec)
        try WorkloadSpecProjector.validate(spec)
        #expect(try WorkloadSpecResolver.launchGuestType(spec) == native)
    }

    @Test func `launchGuestType prefers overlay guestType over fromVM arch`() throws {
        let host = PlatformCapabilities.hostArch
        let native = GuestProfiles.defaultLinuxID(forImageArch: host)
        let foreign = host == "arm64" ? "linux-amd64" : "linux-arm64"
        var vm = VM(
            id: "vm-ov-arch",
            name: "ov",
            vmType: native,
            state: "stopped",
            cpuCount: fixtureCPUCount,
            memoryMb: 1_024,
            bootDiskId: "disk-boot",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
        let overlay = WorkloadSpecOverlay(guestType: foreign)
        vm.setOverrides(
            WorkloadSpecResolver.HostPlatform.current == .linux
                ? WorkloadOverrides(linux: overlay)
                : WorkloadOverrides(macos: overlay),
        )
        let spec = WorkloadSpecProjector.fromVM(vm)
        #expect(spec.spec.arch != nil)
        #expect(try WorkloadSpecResolver.launchGuestType(spec) == foreign)
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecResolver.validate(spec)
        }
    }

    private func specWithHostOverlay(portableGuest: String, overlayGuest: String) -> WorkloadSpec {
        let overlay = WorkloadSpecOverlay(guestType: overlayGuest)
        return WorkloadSpec(
            metadata: WorkloadMetadata(name: "ov"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 1_024),
                guestType: portableGuest,
            ),
            overrides: WorkloadSpecResolver.HostPlatform.current == .linux
                ? WorkloadOverrides(linux: overlay)
                : WorkloadOverrides(macos: overlay),
        )
    }
}
