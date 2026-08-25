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

    @Test func `daemon fatal names the actual socket path and packaging owners`() throws {
        let text = try Self.readRepoFile("Sources/BarkVisorApp/main.swift")
        #expect(text.contains("Socket directory \\(sockets.path)"))
        #expect(text.contains("Homebrew postinstall, pkg, or systemd"))
        #expect(!text.contains("The daemon cannot create /var/run/barkvisor."))
    }

    @Test func `var run socket dir is packaging owned`() {
        #expect(PlatformPaths.socketDirIsPackagingOwned(URL(fileURLWithPath: "/var/run/barkvisor")))
        #expect(PlatformPaths.socketDirIsPackagingOwned(URL(fileURLWithPath: "/private/var/run/barkvisor")))
        #expect(!PlatformPaths.socketDirIsPackagingOwned(URL(fileURLWithPath: "/tmp/barkvisor")))
        #expect(!PlatformPaths.socketDirIsPackagingOwned(URL(fileURLWithPath: "/run/custom-socks")))
    }

    @Test func `isWritableDirectory is false when missing`() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkvisor-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(!PlatformPaths.isWritableDirectory(missing))
    }

    @Test func `isWritableDirectory is true for a created temp dir`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkvisor-writable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PlatformPaths.isWritableDirectory(dir))
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
        #expect(text.contains("RuntimeDirectory=barkvisor"))
        #expect(text.contains("RuntimeDirectoryPreserve=yes"))
        #expect(text.contains("SupplementaryGroups=kvm"))
        #expect(!text.contains("SupplementaryGroups=kvm disk"))
        #expect(!text.contains("KillMode=control-group"))
        let packaged = try Self.readRepoFile("packaging/linux/barkvisor.service")
        #expect(packaged.contains("KillMode=process"))
        #expect(packaged.contains("BARKVISOR_SOCKET_DIR=/var/run/barkvisor"))
        #expect(packaged.contains("RuntimeDirectory=barkvisor"))
        #expect(packaged.contains("RuntimeDirectoryPreserve=yes"))
        #expect(packaged.contains("SupplementaryGroups=kvm"))
        #expect(!packaged.contains("SupplementaryGroups=kvm disk"))
        let postinst = try Self.readRepoFile("packaging/linux/debian/postinst")
        #expect(postinst.contains("usermod -aG disk barkvisor"))
        #expect(postinst.contains("barkvisor.service.d/disk.conf"))
        #expect(postinst.contains("SupplementaryGroups=disk"))
        #expect(postinst.contains("try-restart barkvisor.service"))
    }

    @Test func `pid file parses qemu and swtpm lines`() {
        let both = VMPidFile.parse("1234\n5678\n")
        #expect(both?.qemuPid == 1_234)
        #expect(both?.swtpmPid == 5_678)
        #expect(both?.codingAgentHostPort == nil)
        let qemuOnly = VMPidFile.parse("90\n-1\n")
        #expect(qemuOnly?.qemuPid == 90)
        #expect(qemuOnly?.swtpmPid == nil)
        #expect(qemuOnly?.codingAgentHostPort == nil)
        let withTtyd = VMPidFile.parse("90\n-1\n17681\n")
        #expect(withTtyd?.qemuPid == 90)
        #expect(withTtyd?.swtpmPid == nil)
        #expect(withTtyd?.codingAgentHostPort == 17_681)
        #expect(
            VMPidFile(qemuPid: 90, swtpmPid: nil, codingAgentHostPort: 17_681).serialized()
                == "90\n-1\n17681\n",
        )
        #expect(VMPidFile.parse("not-a-pid") == nil)
        #expect(VMPidFile.parse("") == nil)
    }

    @Test func `reconnected running vm keeps swtpm pid`() {
        let running = RunningVM(
            process: nil,
            pid: 11,
            serialSocketPath: "/tmp/s",
            vncSocketPath: "/tmp/v",
            qmpSocketPath: "/tmp/q",
            qmpEventSocketPath: "/tmp/e",
            swtpmProcess: nil,
            reconnected: true,
            swtpmPid: 22,
        )
        #expect(running.swtpmPid == 22)
        #expect(running.swtpmProcess == nil)
    }

    @Test func `launchd does not reap the process group`() throws {
        let text = try Self.readRepoFile("Resources/dev.barkvisor.plist")
        #expect(text.contains("AbandonProcessGroup"))
        #expect(text.contains("<true/>"))
        let homebrew = try Self.readRepoFile("packaging/homebrew/homebrew.mxcl.barkvisor.plist")
        #expect(homebrew.contains("AbandonProcessGroup"))
        #expect(homebrew.contains("<true/>"))
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
