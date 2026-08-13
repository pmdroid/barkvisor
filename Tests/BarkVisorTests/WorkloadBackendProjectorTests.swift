import Foundation
import Testing
@testable import BarkVisorCore

struct WorkloadBackendProjectorTests {
    private var hostArch: String {
        PlatformCapabilities.hostArch
    }

    private var nativeLinux: String {
        GuestProfiles.defaultLinuxID(forImageArch: hostArch)
    }

    private var foreignLinux: String {
        hostArch == "arm64" ? "linux-amd64" : "linux-arm64"
    }

    @Test func `native guest with hardware accel is not emulated`() {
        let backend = WorkloadBackendProjector.project(
            guestType: nativeLinux,
            accelerator: "kvm",
            hostArch: hostArch,
        )
        #expect(backend.emulated == false)
        #expect(backend.warning == nil)
        #expect(backend.accelerator == "kvm")
        #expect(backend.guestArch == hostArch)
        #expect(backend.qemuBinary == GuestProfiles.profile(for: nativeLinux)?.qemuBinaryName)
    }

    @Test func `native guest on TCG is emulated`() {
        let backend = WorkloadBackendProjector.project(
            guestType: nativeLinux,
            accelerator: "tcg",
            hostArch: hostArch,
        )
        #expect(backend.emulated)
        #expect(backend.accelerator == "tcg")
        #expect(backend.warning?.contains("TCG") == true)
        #expect(backend.warning?.contains("slower") == true)
    }

    @Test func `cross-arch guest is emulated even with hardware accel name`() {
        let backend = WorkloadBackendProjector.project(
            guestType: foreignLinux,
            accelerator: "hvf",
            hostArch: hostArch,
        )
        #expect(backend.emulated)
        #expect(backend.guestArch != hostArch)
        #expect(backend.warning?.contains("does not match") == true)
        #expect(backend.qemuBinary == GuestProfiles.profile(for: foreignLinux)?.qemuBinaryName)
    }

    @Test func `default accelerator matches QEMUBuilder launch`() {
        let backend = WorkloadBackendProjector.project(guestType: nativeLinux)
        #expect(backend.accelerator == QEMUBuilder.accelerator)
        #expect(backend.accelerator == PlatformCapabilities.accelerator)
    }

    @Test func `unknown guest type does not invent arch or binary`() {
        let backend = WorkloadBackendProjector.project(
            guestType: "not-a-real-type",
            accelerator: "kvm",
            hostArch: hostArch,
        )
        #expect(backend.guestArch.isEmpty)
        #expect(backend.qemuBinary.isEmpty)
        #expect(backend.emulated == false)
    }

    @Test func `backend encodes camelCase status fields`() throws {
        let backend = WorkloadBackendProjector.project(
            guestType: nativeLinux,
            accelerator: "tcg",
            hostArch: hostArch,
        )
        let data = try JSONEncoder().encode(backend)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["accelerator"] as? String == "tcg")
        #expect(object?["guestArch"] as? String == hostArch)
        #expect(object?["qemuBinary"] as? String == GuestProfiles.profile(for: nativeLinux)?.qemuBinaryName)
        #expect(object?["emulated"] as? Bool == true)
        #expect((object?["warning"] as? String)?.isEmpty == false)
    }
}
