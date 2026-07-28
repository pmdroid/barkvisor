import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct SystemAboutController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("onboarding", use: getOnboarding)
        system.post("onboarding", "complete", use: completeOnboarding)
        system.get("about", use: getAbout)
    }

    // MARK: - Onboarding

    @Sendable
    func getOnboarding(req: Vapor.Request) async throws -> OnboardingStatus {
        let setting = try await req.db.read { db in
            try AppSetting.fetchOne(db, key: "onboarding_complete")
        }
        return OnboardingStatus(complete: setting?.value == "true")
    }

    @Sendable
    func completeOnboarding(req: Vapor.Request) async throws -> OnboardingStatus {
        try await req.db.write { db in
            let setting = AppSetting(key: "onboarding_complete", value: "true")
            try setting.save(db, onConflict: .replace)
        }
        return OnboardingStatus(complete: true)
    }

    // MARK: - About / Licenses

    @Sendable
    func getAbout(req: Vapor.Request) async throws -> AppInfoResponse {
        AppInfoResponse(
            version: Config.version,
            licenses: [
                LicenseEntry(
                    name: "QEMU",
                    license: "GPL-2.0",
                    url: "https://www.qemu.org/",
                    description: "Machine emulator and virtualizer. Source code available at qemu.org.",
                ),
                LicenseEntry(
                    name: "edk2 / OVMF / AAVMF",
                    license: "BSD-2-Clause",
                    url: "https://github.com/tianocore/edk2",
                    description: "UEFI firmware for virtual machines.",
                ),
                LicenseEntry(
                    name: "swtpm",
                    license: "BSD-3-Clause",
                    url: "https://github.com/stefanberger/swtpm",
                    description: "Software TPM 2.0 emulator.",
                ),
                LicenseEntry(
                    name: "libtpms",
                    license: "BSD-3-Clause",
                    url: "https://github.com/stefanberger/libtpms",
                    description: "TPM emulation library.",
                ),
                LicenseEntry(
                    name: "socket_vmnet",
                    license: "Apache-2.0",
                    url: "https://github.com/lima-vm/socket_vmnet",
                    description: "Bridged networking for QEMU on macOS.",
                ),
                LicenseEntry(
                    name: "virtio-win",
                    license: "Red Hat (various)",
                    url: "https://github.com/virtio-win/virtio-win-pkg-scripts",
                    description: "VirtIO drivers for Windows guests.",
                ),
                LicenseEntry(
                    name: "noVNC",
                    license: "MPL-2.0",
                    url: "https://novnc.com/",
                    description: "HTML5 VNC client for browser-based display.",
                ),
                LicenseEntry(
                    name: "xterm.js",
                    license: "MIT",
                    url: "https://xtermjs.org/",
                    description: "Terminal emulator for the serial console.",
                ),
                LicenseEntry(
                    name: "Vue.js",
                    license: "MIT",
                    url: "https://vuejs.org/",
                    description: "Frontend framework.",
                ),
                LicenseEntry(
                    name: "Vapor",
                    license: "MIT",
                    url: "https://vapor.codes/",
                    description: "Swift HTTP server framework.",
                ),
                LicenseEntry(
                    name: "GRDB.swift",
                    license: "MIT",
                    url: "https://github.com/groue/GRDB.swift",
                    description: "SQLite toolkit for Swift.",
                ),
                LicenseEntry(
                    name: "XZ Utils",
                    license: "Public domain / LGPL-2.1",
                    url: "https://tukaani.org/xz/",
                    description: "XZ/LZMA decompression tool (bundled).",
                ),
            ],
        )
    }
}
