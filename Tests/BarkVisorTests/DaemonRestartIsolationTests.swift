import Foundation
import Testing
@testable import BarkVisorCore

/// PAS-223: daemon restart must not take Workloads down with it.
struct DaemonRestartIsolationTests {
    @Test func `socket dir override wins`() {
        let dir = PlatformPaths.resolveSocketDir(
            isInstalled: false,
            dataDir: URL(fileURLWithPath: "/tmp/other"),
            socketDirOverride: "/run/custom-socks",
            temporaryDirectory: "/tmp",
        )
        #expect(dir.path == "/run/custom-socks")
    }

    @Test func `installed layout uses var run`() {
        let dir = PlatformPaths.resolveSocketDir(
            isInstalled: true,
            dataDir: URL(fileURLWithPath: "/var/lib/barkvisor"),
            socketDirOverride: nil,
            temporaryDirectory: "/tmp",
        )
        #expect(dir.path == "/var/run/barkvisor")
    }

    @Test func `systemd data dir uses var run even without libexec qemu`() {
        let dir = PlatformPaths.resolveSocketDir(
            isInstalled: false,
            dataDir: URL(fileURLWithPath: "/var/lib/barkvisor"),
            socketDirOverride: nil,
            temporaryDirectory: "/tmp",
        )
        #expect(dir.path == "/var/run/barkvisor")
    }

    @Test func `dev layout stays under tmp`() {
        let dir = PlatformPaths.resolveSocketDir(
            isInstalled: false,
            dataDir: URL(fileURLWithPath: "/home/dev/.local/share/barkvisor"),
            socketDirOverride: nil,
            temporaryDirectory: "/tmp",
        )
        #expect(dir.path == "/tmp/barkvisor")
    }

    @Test func `systemd unit only kills the daemon process`() throws {
        let text = try Self.readRepoFile("Resources/barkvisor.service")
        #expect(text.contains("KillMode=process"))
        #expect(text.contains("BARKVISOR_SOCKET_DIR=/var/run/barkvisor"))
        #expect(!text.contains("KillMode=control-group"))
        let packaged = try Self.readRepoFile("packaging/linux/barkvisor.service")
        #expect(packaged.contains("KillMode=process"))
        #expect(packaged.contains("BARKVISOR_SOCKET_DIR=/var/run/barkvisor"))
    }

    @Test func `launchd does not reap the process group`() throws {
        let text = try Self.readRepoFile("Resources/dev.barkvisor.plist")
        #expect(text.contains("AbandonProcessGroup"))
        #expect(text.contains("<true/>"))
    }

    private static func readRepoFile(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        let file = url.appendingPathComponent(relative)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
