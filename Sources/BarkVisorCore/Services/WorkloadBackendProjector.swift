import Foundation

/// Effective per-VM backend (accelerator, guest arch, QEMU binary).
///
/// Same inputs `QEMUBuilder.launchConfig` uses so API status matches launch args.
public enum WorkloadBackendProjector {
    public static func project(
        guestType: String,
        accelerator: String = QEMUBuilder.accelerator,
        hostArch: String = PlatformCapabilities.hostArch,
    ) -> VMRuntimeBackend {
        let profile = GuestProfiles.profile(for: guestType)
        let guestArch = profile?.arch ?? ""
        let qemuBinary = profile?.qemuBinaryName ?? ""
        let host = PlatformCapabilities.normalizedArch(hostArch)
        let guest = PlatformCapabilities.normalizedArch(guestArch)
        let crossArch = !guest.isEmpty && guest != host
        let tcg = accelerator == "tcg"
        let emulated = tcg || crossArch
        return VMRuntimeBackend(
            accelerator: accelerator,
            guestArch: guestArch,
            qemuBinary: qemuBinary,
            emulated: emulated,
            warning: warning(tcg: tcg, crossArch: crossArch, guest: guest, host: host),
        )
    }

    public static func project(
        vm: VM,
        accelerator: String = QEMUBuilder.accelerator,
        hostArch: String = PlatformCapabilities.hostArch,
    ) -> VMRuntimeBackend {
        project(guestType: vm.vmType, accelerator: accelerator, hostArch: hostArch)
    }

    private static func warning(
        tcg: Bool,
        crossArch: Bool,
        guest: String,
        host: String,
    ) -> String? {
        if crossArch, tcg {
            return """
            This guest architecture (\(guest)) does not match the host (\(host)), \
            so QEMU is using TCG software emulation. Guests will be significantly slower.
            """
        }
        if crossArch {
            return """
            This guest architecture (\(guest)) does not match the host (\(host)). \
            Hardware acceleration cannot be used; performance will be much slower.
            """
        }
        if tcg {
            return """
            This workload is using TCG software emulation instead of hardware \
            acceleration. Guests will be significantly slower.
            """
        }
        return nil
    }
}
