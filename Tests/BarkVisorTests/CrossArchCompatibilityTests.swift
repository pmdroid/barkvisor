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

    /// Document the acceptance-criteria direction explicitly when running on arm64.
    @Test func `x86_64 workload blocked on arm64 host`() throws {
        try #require(PlatformCapabilities.hostArch == "arm64")
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch("x86_64")
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                try GuestProfiles.require("linux-amd64").arch,
            )
        }
    }

    /// Symmetric guard when CI/dev hosts are x86_64 (this environment).
    @Test func `arm64 workload blocked on x86_64 host`() throws {
        try #require(PlatformCapabilities.hostArch == "x86_64")
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch("arm64")
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                try GuestProfiles.require("linux-arm64").arch,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try PlatformCapabilities.requireCompatibleGuestArch(
                try GuestProfiles.require("windows-arm64").arch,
            )
        }
    }
}
