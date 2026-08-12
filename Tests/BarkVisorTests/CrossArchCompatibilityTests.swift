import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct CrossArchCompatibilityTests {
    // MARK: - Arch normalization

    @Test func `normalizedArch maps common aliases`() {
        #expect(PlatformCapabilities.normalizedArch("arm64") == "arm64")
        #expect(PlatformCapabilities.normalizedArch("aarch64") == "arm64")
        #expect(PlatformCapabilities.normalizedArch("x86_64") == "x86_64")
        #expect(PlatformCapabilities.normalizedArch("amd64") == "x86_64")
    }

    // MARK: - Create/deploy validation wiring

    /// `validateCreateVMInputs` is shared by create + template deploy.
    @Test func `validateCreateVMInputs blocks foreign guest arch`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(M001_CreateSchema.identifier) { db in
            try M001_CreateSchema.migrate(db)
        }
        try migrator.migrate(pool)

        let host = PlatformCapabilities.hostArch
        let foreignType = host == "arm64" ? "linux-amd64" : "linux-arm64"
        let params = CreateVMParams(
            name: "cross-arch-guard",
            vmType: foreignType,
            cpuCount: 1,
            memoryMB: 512,
            cloudImageId: "img-unused",
        )

        do {
            try await VMLifecycleService.validateCreateVMInputs(params: params, db: pool)
            Issue.record("expected validateCreateVMInputs to reject \(foreignType) on \(host)")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.lowercased().contains("not compatible")
                || message.lowercased().contains("cross-architecture"))
            #expect(message.contains(host))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Host ↔ guest compatibility

    @Test func `same arch guest is compatible`() {
        let host = PlatformCapabilities.hostArch
        #expect(PlatformCapabilities.isCompatibleGuestArch(host))
        #expect(throws: Never.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(host)
        }
        // Aliases of the host arch must also pass.
        if host == "arm64" {
            #expect(PlatformCapabilities.isCompatibleGuestArch("aarch64"))
            #expect(throws: Never.self) {
                try PlatformCapabilities.requireCompatibleGuestArch("aarch64")
            }
        } else if host == "x86_64" {
            #expect(PlatformCapabilities.isCompatibleGuestArch("amd64"))
            #expect(throws: Never.self) {
                try PlatformCapabilities.requireCompatibleGuestArch("amd64")
            }
        }
    }

    @Test func `cross arch guest is blocked with clear reason`() {
        let host = PlatformCapabilities.hostArch
        let foreign = host == "arm64" ? "x86_64" : "arm64"

        #expect(!PlatformCapabilities.isCompatibleGuestArch(foreign))

        do {
            try PlatformCapabilities.requireCompatibleGuestArch(foreign)
            Issue.record("expected requireCompatibleGuestArch to throw for \(foreign) on \(host)")
        } catch let BarkVisorError.badRequest(message) {
            #expect(message.contains(foreign))
            #expect(message.contains(host))
            #expect(message.lowercased().contains("not compatible")
                || message.lowercased().contains("cross-architecture"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Core PAS-48 matrix case expressed relative to the running host:
    /// foreign GuestProfile.arch must be rejected before QEMU is launched.
    @Test func `foreign guest profile arch is rejected`() throws {
        let host = PlatformCapabilities.hostArch
        let foreignProfiles = GuestProfiles.all.filter { $0.arch != host }
        #expect(!foreignProfiles.isEmpty)

        for profile in foreignProfiles {
            #expect(!PlatformCapabilities.isCompatibleGuestArch(profile.arch))
            #expect(throws: BarkVisorError.self) {
                try PlatformCapabilities.requireCompatibleGuestArch(profile.arch)
            }
        }

        let nativeProfiles = GuestProfiles.all.filter { $0.arch == host }
        #expect(!nativeProfiles.isEmpty)
        for profile in nativeProfiles {
            try PlatformCapabilities.requireCompatibleGuestArch(profile.arch)
        }
    }

    /// Acceptance-criteria direction (PAS-48): x86_64 workload on arm64 host.
    @Test(.enabled(if: PlatformCapabilities.hostArch == "arm64"))
    func `x86_64 workload blocked on arm64 host`() throws {
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch("x86_64")
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                GuestProfiles.require("linux-amd64").arch,
            )
        }
    }

    /// Symmetric guard on x86_64 CI/dev hosts.
    @Test(.enabled(if: PlatformCapabilities.hostArch == "x86_64"))
    func `arm64 workload blocked on x86_64 host`() throws {
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch("arm64")
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                GuestProfiles.require("linux-arm64").arch,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                GuestProfiles.require("windows-arm64").arch,
            )
        }
    }
}
