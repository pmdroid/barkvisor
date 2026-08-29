import Foundation
import Testing
@testable import BarkVisorCore

struct UpdateServiceTests {
    @Test func `prerelease numeric bump`() {
        #expect(UpdateService.isVersion("1.0.0-alpha.2", newerThan: "1.0.0-alpha.1"))
        #expect(UpdateService.isVersion("1.0.0-alpha.10", newerThan: "1.0.0-alpha.9"))
    }

    @Test func `release newer than prerelease`() {
        #expect(UpdateService.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        #expect(!UpdateService.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
    }

    @Test func `same version not newer`() {
        #expect(!UpdateService.isVersion("1.0.0", newerThan: "1.0.0"))
        #expect(UpdateService.isVersion("2.0.0", newerThan: "1.9.9"))
    }

    @Test func `checksum parse takes first hex token`() {
        #expect(UpdateChecksum.parse("abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234  file.deb")
            == "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234")
        #expect(UpdateChecksum.parse("not-a-hash") == nil)
        #expect(UpdateChecksum.parse("") == nil)
    }

    @Test func `deb asset matches host arch and refuses rpm`() {
        let amd = PlatformCapabilities.normalizedArch("x86_64")
        #expect(UpdateReleaseParser.matches(
            name: "barkvisor_1.2.3_amd64.deb",
            kind: .deb,
            hostArch: amd,
        ))
        #expect(!UpdateReleaseParser.matches(
            name: "barkvisor_1.2.3_arm64.deb",
            kind: .deb,
            hostArch: amd,
        ))
        #expect(!UpdateReleaseParser.matches(
            name: "barkvisor-1.2.3-1.x86_64.rpm",
            kind: .deb,
            hostArch: amd,
        ))
        #expect(UpdateReleaseParser.matches(
            name: "BarkVisor-1.2.3.pkg",
            kind: .pkg,
            hostArch: "arm64",
        ))
        #expect(!UpdateReleaseParser.matches(
            name: "BarkVisor-1.2.3.pkg.sha256",
            kind: .pkg,
            hostArch: "arm64",
        ))
        #expect(!UpdateReleaseParser.matches(
            name: "barkvisor-1.2.3.bottle.tar.gz",
            kind: .pkg,
            hostArch: "arm64",
        ))
    }

    @Test func `pick requires checksum and skips older releases`() throws {
        let releases = [
            UpdateReleaseParser.Release(
                tagName: "v1.2.3",
                prerelease: false,
                body: "notes",
                publishedAt: "2026-08-01T00:00:00Z",
                assets: [
                    .init(
                        name: "barkvisor_1.2.3_arm64.deb",
                        url: "https://example.test/barkvisor_1.2.3_arm64.deb",
                    ),
                    .init(
                        name: "barkvisor_1.2.3_arm64.deb.sha256",
                        url: "https://example.test/barkvisor_1.2.3_arm64.deb.sha256",
                    ),
                    .init(name: "barkvisor-1.2.3-1.aarch64.rpm", url: "https://example.test/skip.rpm"),
                ],
            ),
        ]
        let info = try UpdateReleaseParser.pick(
            releases: releases,
            channel: .stable,
            currentVersion: "1.0.0",
            kind: .deb,
            hostArch: "arm64",
        )
        #expect(info?.version == "1.2.3")
        #expect(info?.packageKind == .deb)
        #expect(info?.packageURL.hasSuffix(".deb") == true)
        #expect(info?.checksumURL.hasSuffix(".deb.sha256") == true)

        let none = try UpdateReleaseParser.pick(
            releases: releases,
            channel: .stable,
            currentVersion: "1.2.3",
            kind: .deb,
            hostArch: "arm64",
        )
        #expect(none == nil)
    }

    @Test func `missing checksum refuses the release`() throws {
        let releases = [
            UpdateReleaseParser.Release(
                tagName: "v2.0.0",
                prerelease: false,
                body: "",
                publishedAt: "2026-08-01T00:00:00Z",
                assets: [
                    .init(name: "BarkVisor-2.0.0.pkg", url: "https://example.test/BarkVisor-2.0.0.pkg"),
                ],
            ),
        ]
        #expect(throws: BarkVisorError.self) {
            _ = try UpdateReleaseParser.pick(
                releases: releases,
                channel: .stable,
                currentVersion: "1.0.0",
                kind: .pkg,
                hostArch: "arm64",
                wantVersion: "2.0.0",
            )
        }
    }

    @Test func `install plan is dpkg or installer never brew`() {
        let deb = AppliancePackageInstaller.plan(kind: .deb, packagePath: "/tmp/bv.deb")
        #expect(deb.installExecutable == "/usr/bin/dpkg")
        #expect(deb.installArguments == ["-i", "/tmp/bv.deb"])
        #expect(deb.fixDependsExecutable == "/usr/bin/apt-get")
        #expect(deb.fixDependsArguments == ["-f", "install", "-y"])
        #expect(deb.restartArguments == ["restart", "barkvisor.service"])
        #expect(!deb.mentionsBrew)

        let pkg = AppliancePackageInstaller.plan(kind: .pkg, packagePath: "/tmp/bv.pkg")
        #expect(pkg.installExecutable == "/usr/sbin/installer")
        #expect(pkg.installArguments == ["-pkg", "/tmp/bv.pkg", "-target", "/"])
        #expect(pkg.restartArguments == ["kickstart", "-k", "system/dev.barkvisor"])
        #expect(!pkg.mentionsBrew)
        #expect(!pkg.commandLines.joined().contains("sudo"))
    }

    @Test func `apt-get -f only when dpkg reports depends`() {
        #expect(AppliancePackageInstaller.shouldFixDepends(
            exitCode: 1,
            output: "dpkg: dependency problems prevent configuration",
        ))
        #expect(!AppliancePackageInstaller.shouldFixDepends(exitCode: 0, output: "ok"))
        #expect(!AppliancePackageInstaller.shouldFixDepends(exitCode: 2, output: "I/O error"))
    }
}
