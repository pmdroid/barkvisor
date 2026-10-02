import Testing
@testable import BarkVisorCore

struct UpdateSettingsTests {
    @Test(arguments: ["1.0.0", "1.0.0+git.build-1", "0.0.0+git.hash"])
    func `stable versions default to stable`(version: String) {
        #expect(UpdateChannel.defaultChannel(for: version) == .stable)
    }

    @Test(arguments: ["1.0.0-alpha.12", "1.0.0-beta.1", "1.0.0-rc.1", "0.0.0-dev", "1.0.0-alpha.12+build.1"])
    func `prerelease versions default to beta`(version: String) {
        #expect(UpdateChannel.defaultChannel(for: version) == .beta)
    }

    @Test func `unset prerelease channel offers newer prereleases`() throws {
        let releases = [UpdateReleaseParser.Release(
            tagName: "v1.0.0-alpha.13",
            prerelease: true,
            body: "notes",
            publishedAt: "2026-10-01T00:00:00Z",
            assets: [
                .init(name: "barkvisor_1.0.0-alpha.13_arm64.deb", url: "https://example.test/update.deb"),
                .init(name: "barkvisor_1.0.0-alpha.13_arm64.deb.sha256", url: "https://example.test/update.deb.sha256"),
            ],
        )]
        let update = try UpdateReleaseParser.pick(
            releases: releases,
            channel: UpdateChannel.defaultChannel(for: "1.0.0-alpha.12"),
            currentVersion: "1.0.0-alpha.12",
            kind: .deb,
            hostArch: "arm64",
        )
        #expect(update?.version == "1.0.0-alpha.13")
        let stable = try UpdateReleaseParser.pick(
            releases: releases,
            channel: .stable,
            currentVersion: "1.0.0-alpha.12",
            kind: .deb,
            hostArch: "arm64",
        )
        #expect(stable == nil)
    }
}
