import Foundation
import Testing
@testable import BarkVisorCore

/// PAS-293: installed layout is share frontend / data-dir override, not libexec QEMU.
struct PlatformPathsInstalledLayoutTests {
    private let homebrewPrefix = "/opt/homebrew"
    private let usrLocalPrefix = "/usr/local"

    @Test func `share frontend index is under prefix share barkvisor`() {
        #expect(
            PlatformPaths.shareFrontendIndexPath(prefix: homebrewPrefix)
                == "/opt/homebrew/share/barkvisor/frontend/dist/index.html",
        )
        #expect(
            PlatformPaths.shareFrontendIndexPath(prefix: usrLocalPrefix)
                == "/usr/local/share/barkvisor/frontend/dist/index.html",
        )
    }

    @Test func `homebrew prefix with share frontend is installed without qemu`() {
        #expect(
            PlatformPaths.isInstalled(
                prefix: homebrewPrefix,
                binaryDirectoryIsBin: true,
                dataDirOverride: nil,
                fileExists: { $0 == PlatformPaths.shareFrontendIndexPath(prefix: homebrewPrefix) },
            ),
        )
    }

    @Test func `usr local prefix with share frontend is installed without qemu`() {
        #expect(
            PlatformPaths.isInstalled(
                prefix: usrLocalPrefix,
                binaryDirectoryIsBin: true,
                dataDirOverride: nil,
                fileExists: { $0 == PlatformPaths.shareFrontendIndexPath(prefix: usrLocalPrefix) },
            ),
        )
    }

    @Test func `libexec qemu alone is not installed`() {
        let leftoverQEMU = [
            "/usr/local/libexec/barkvisor/qemu-system-aarch64",
            "/usr/local/libexec/barkvisor/qemu-system-x86_64",
            "/opt/homebrew/libexec/barkvisor/qemu-system-aarch64",
            "/opt/homebrew/libexec/barkvisor/qemu-system-x86_64",
        ]
        #expect(
            !PlatformPaths.isInstalled(
                prefix: usrLocalPrefix,
                binaryDirectoryIsBin: true,
                dataDirOverride: nil,
                fileExists: { leftoverQEMU.contains($0) },
            ),
        )
        #expect(
            !PlatformPaths.isInstalled(
                prefix: homebrewPrefix,
                binaryDirectoryIsBin: true,
                dataDirOverride: nil,
                fileExists: { leftoverQEMU.contains($0) },
            ),
        )
    }

    @Test func `swift run without share frontend is not installed`() {
        #expect(
            !PlatformPaths.isInstalled(
                prefix: usrLocalPrefix,
                binaryDirectoryIsBin: false,
                dataDirOverride: nil,
                fileExists: { _ in false },
            ),
        )
    }

    @Test func `swift run ignores a leftover pkg frontend at usr local`() {
        #expect(
            !PlatformPaths.isInstalled(
                prefix: usrLocalPrefix,
                binaryDirectoryIsBin: false,
                dataDirOverride: nil,
                fileExists: { $0 == PlatformPaths.shareFrontendIndexPath(prefix: usrLocalPrefix) },
            ),
        )
    }

    @Test func `data dir override marks installed without frontend`() {
        #expect(
            PlatformPaths.isInstalled(
                prefix: homebrewPrefix,
                binaryDirectoryIsBin: false,
                dataDirOverride: "/var/lib/barkvisor",
                fileExists: { _ in false },
            ),
        )
    }

    @Test func `empty data dir override does not mark installed`() {
        #expect(
            !PlatformPaths.isInstalled(
                prefix: usrLocalPrefix,
                binaryDirectoryIsBin: true,
                dataDirOverride: "",
                fileExists: { _ in false },
            ),
        )
    }

    @Test func `installed data dir is var lib not homebrew prefix var`() {
        let dir = PlatformPaths.dataDir(isInstalled: true, dataDirOverride: nil)
        #expect(dir.path == "/var/lib/barkvisor")
        #expect(!dir.path.contains("homebrew"))
        #expect(!dir.path.contains("/usr/local/var"))
    }

    @Test func `dev data dir is not var lib when override is absent`() {
        let dir = PlatformPaths.dataDir(isInstalled: false, dataDirOverride: nil)
        #expect(dir.path != "/var/lib/barkvisor")
        #expect(dir.path.localizedCaseInsensitiveContains("barkvisor"))
    }

    @Test func `data dir override wins over installed default`() {
        let dir = PlatformPaths.dataDir(
            isInstalled: true,
            dataDirOverride: "/tmp/barkvisor-test-data",
        )
        #expect(dir.path == "/tmp/barkvisor-test-data")
    }

    @Test func `installed layout socket dir is var run`() {
        let dir = PlatformPaths.resolveSocketDir(
            isInstalled: true,
            dataDir: URL(fileURLWithPath: "/var/lib/barkvisor"),
            socketDirOverride: nil,
            temporaryDirectory: "/tmp",
        )
        #expect(dir.path == "/var/run/barkvisor")
    }

    @Test func `var lib data dir keeps var run sockets without isInstalled`() {
        let dir = PlatformPaths.resolveSocketDir(
            isInstalled: false,
            dataDir: URL(fileURLWithPath: "/var/lib/barkvisor"),
            socketDirOverride: nil,
            temporaryDirectory: "/tmp",
        )
        #expect(dir.path == "/var/run/barkvisor")
    }
}
