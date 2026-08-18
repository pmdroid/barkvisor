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
        #expect(text.contains("RuntimeDirectory=barkvisor"))
        #expect(text.contains("RuntimeDirectoryPreserve=yes"))
        #expect(!text.contains("KillMode=control-group"))
        let packaged = try Self.readRepoFile("packaging/linux/barkvisor.service")
        #expect(packaged.contains("KillMode=process"))
        #expect(packaged.contains("BARKVISOR_SOCKET_DIR=/var/run/barkvisor"))
        #expect(packaged.contains("RuntimeDirectory=barkvisor"))
        #expect(packaged.contains("RuntimeDirectoryPreserve=yes"))
    }

    @Test func `pid file parses qemu and swtpm lines`() {
        let both = VMPidFile.parse("1234\n5678\n")
        #expect(both?.qemuPid == 1_234)
        #expect(both?.swtpmPid == 5_678)
        let qemuOnly = VMPidFile.parse("90\n-1\n")
        #expect(qemuOnly?.qemuPid == 90)
        #expect(qemuOnly?.swtpmPid == nil)
        #expect(VMPidFile.parse("not-a-pid") == nil)
        #expect(VMPidFile.parse("") == nil)
    }

    @Test func `qemu argv parse reads uuid and sockets`() {
        let args = [
            "/usr/bin/qemu-system-x86_64",
            "-name", "hermes",
            "-uuid", "6FB33A30-F139-4DE5-80EB-1DA1883696B1",
            "-chardev", "socket,id=serial0,path=/tmp/barkvisor/6FB33A30-F13-ser.sock,server=on,wait=off",
            "-vnc", "unix:/tmp/barkvisor/6FB33A30-F13-vnc.sock,lossy=on",
            "-qmp", "unix:/tmp/barkvisor/6FB33A30-F13-qmp.sock,server,nowait",
            "-qmp", "unix:/tmp/barkvisor/6FB33A30-F13-evt.sock,server,nowait",
        ]
        let record = QEMUProcessRecord.parse(pid: 334_901, arguments: args)
        #expect(record?.vmID == "6FB33A30-F139-4DE5-80EB-1DA1883696B1")
        #expect(record?.pid == 334_901)
        #expect(record?.serialSocketPath == "/tmp/barkvisor/6FB33A30-F13-ser.sock")
        #expect(record?.vncSocketPath == "/tmp/barkvisor/6FB33A30-F13-vnc.sock")
        #expect(record?.qmpSocketPath == "/tmp/barkvisor/6FB33A30-F13-qmp.sock")
        #expect(record?.qmpEventSocketPath == "/tmp/barkvisor/6FB33A30-F13-evt.sock")
        #expect(QEMUProcessRecord.parse(pid: 1, arguments: ["bash", "-c", "echo"]) == nil)
        #expect(QEMUProcessRecord.parse(pid: 1, arguments: ["qemu-system-x86_64", "-name", "x"]) == nil)
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
