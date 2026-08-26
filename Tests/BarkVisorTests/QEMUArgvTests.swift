import Foundation
import Testing
@testable import BarkVisorCore

struct QEMUArgvTests {
    private static let vmID = "85E9313A-17B3-406B-9056-2818AE6AC177"
    private static let bootDisk = "/var/lib/barkvisor/disks/85E9313A-17B3-406B-9056-2818AE6AC177.qcow2"

    private static let fixture: [String] = [
        "/usr/bin/qemu-system-x86_64",
        "-name", "test-raw",
        "-uuid", "6FB33A30-F139-4DE5-80EB-1DA1883696B1",
        "-drive", "file=\(bootDisk),format=qcow2,if=none,id=boot0,cache=writeback",
        "-chardev", "socket,id=serial0,path=/var/run/barkvisor/6FB33A30-F13-ser.sock,server=on,wait=off",
        "-vnc", "unix:/var/run/barkvisor/6FB33A30-F13-vnc.sock,lossy=on",
        "-qmp", "unix:/var/run/barkvisor/6FB33A30-F13-qmp.sock,server,nowait",
        "-qmp", "unix:/var/run/barkvisor/6FB33A30-F13-evt.sock,server,nowait",
    ]

    @Test func `fixture argv parses identity sockets and drives`() throws {
        let argv = try #require(QEMUArgv(arguments: Self.fixture))
        #expect(argv.uuid == "6FB33A30-F139-4DE5-80EB-1DA1883696B1")
        #expect(argv.guestName == "test-raw")
        #expect(argv.driveFilePaths == [Self.bootDisk])
        #expect(argv.serialSocketPath == "/var/run/barkvisor/6FB33A30-F13-ser.sock")
        #expect(argv.vncSocketPath == "/var/run/barkvisor/6FB33A30-F13-vnc.sock")
        #expect(argv.qmpSocketPaths.count == 2)
        #expect(argv.qmpSocketPaths.first == "/var/run/barkvisor/6FB33A30-F13-qmp.sock")
        #expect(argv.qmpSocketPaths.last == "/var/run/barkvisor/6FB33A30-F13-evt.sock")
    }

    @Test func `non qemu argv is rejected`() {
        #expect(QEMUArgv(arguments: []) == nil)
        #expect(QEMUArgv(arguments: ["/bin/bash", "-c", "echo hi"]) == nil)
        #expect(QEMUArgv(arguments: ["/usr/local/bin/swtpm", "socket", "--tpmstate"]) == nil)
        #expect(QEMUArgv(arguments: Self.fixture) != nil)
        #expect(QEMUArgv(arguments: ["qemu-system-aarch64", "-uuid", "X"]) != nil)
        let wrapped = ["/opt/socket_vmnet/bin/socket_vmnet_client", "/run/socket_vmnet"] + Self.fixture
        #expect(QEMUArgv(arguments: wrapped)?.uuid == "6FB33A30-F139-4DE5-80EB-1DA1883696B1")
    }

    @Test func `multiple drive specs are all extracted`() {
        var args = Self.fixture
        args.append(contentsOf: [
            "-drive", "file=/var/lib/barkvisor/disks/data01.qcow2,format=qcow2,if=none,id=data0",
            "-drive", "format=raw,if=none,id=bare",
        ])
        let argv = QEMUArgv(arguments: args)
        #expect(argv?.driveFilePaths == [
            Self.bootDisk,
            "/var/lib/barkvisor/disks/data01.qcow2",
        ])
    }

    @Test func `write lock detector matches qemu lock stderr`() {
        let line = "qemu-system-x86_64: -drive file=/disks/a.qcow2,format=qcow2: Failed to get "
            + "\"write\" lock Is another process using the image [...]?"
        #expect(QEMUArgv.reportsWriteLock(line))
        #expect(QEMUArgv.reportsWriteLock("Failed to get \"write\" lock"))
        #expect(QEMUArgv.reportsWriteLock("Is another process using the image"))
        #expect(!QEMUArgv.reportsWriteLock("Could not set up host forwarding rule"))
        #expect(!QEMUArgv.reportsWriteLock(""))
    }

    @Test func `reconnect decision table never kills on missing sockets`() {
        let vmID = Self.vmID
        #expect(
            QEMUArgv.reconnectDecision(
                pidAlive: false, executableIsQEMU: true,
                argvUUID: vmID, vmID: vmID,
            ) == .cleanupDead,
        )
        #expect(
            QEMUArgv.reconnectDecision(
                pidAlive: true, executableIsQEMU: false,
                argvUUID: nil, vmID: vmID,
            ) == .dropStalePidFile,
        )
        #expect(
            QEMUArgv.reconnectDecision(
                pidAlive: true, executableIsQEMU: false,
                argvUUID: vmID, vmID: vmID,
            ) == .dropStalePidFile,
        )
        #expect(
            QEMUArgv.reconnectDecision(
                pidAlive: true, executableIsQEMU: true,
                argvUUID: "FFFFFFFF-0000-0000-0000-000000000000", vmID: vmID,
            ) == .dropStalePidFile,
        )
        #expect(
            QEMUArgv.reconnectDecision(
                pidAlive: true, executableIsQEMU: true,
                argvUUID: vmID.lowercased(), vmID: vmID,
            ) == .adopt,
        )
        #expect(
            QEMUArgv.reconnectDecision(
                pidAlive: true, executableIsQEMU: true,
                argvUUID: nil, vmID: vmID,
            ) == .adopt,
        )
    }

    @Test func `disk holder adopts self uuid over foreign order`() {
        let selfEntry: QEMUArgv.ProcessEntry = (
            pid: 101,
            arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-uuid", Self.vmID,
                "-drive", "file=\(Self.bootDisk),format=qcow2",
            ],
        )
        #expect(
            QEMUArgv.diskHolder(diskPaths: [Self.bootDisk], vmID: Self.vmID, processes: [selfEntry])
                == .selfProcess(pid: 101),
        )
    }

    @Test func `disk holder reports foreign qemu with name and pid`() {
        let foreign: QEMUArgv.ProcessEntry = (
            pid: 202,
            arguments: Self.fixture,
        )
        #expect(
            QEMUArgv.diskHolder(diskPaths: [Self.bootDisk], vmID: Self.vmID, processes: [foreign])
                == .foreign(pid: 202, guestName: "test-raw"),
        )
    }

    @Test func `disk holder without uuid is still a foreign conflict`() {
        let unknown: QEMUArgv.ProcessEntry = (
            pid: 303,
            arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-name", "mystery",
                "-drive", "file=\(Self.bootDisk),format=raw",
            ],
        )
        #expect(
            QEMUArgv.diskHolder(diskPaths: [Self.bootDisk], vmID: Self.vmID, processes: [unknown])
                == .foreign(pid: 303, guestName: "mystery"),
        )
    }

    @Test func `disk holder ignores unrelated and non qemu processes`() {
        let unrelatedQemu: QEMUArgv.ProcessEntry = (
            pid: 404,
            arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-uuid", "EEEEEEEE-0000-0000-0000-000000000000",
                "-drive", "file=/var/lib/barkvisor/disks/other-disk.qcow2,format=qcow2",
            ],
        )
        let notQemu: QEMUArgv.ProcessEntry = (
            pid: 405,
            arguments: ["/bin/dd", "if=\(Self.bootDisk)", "of=/dev/null"],
        )
        #expect(
            QEMUArgv.diskHolder(
                diskPaths: [Self.bootDisk],
                vmID: Self.vmID,
                processes: [unrelatedQemu, notQemu],
            ) == nil,
        )
        #expect(
            QEMUArgv.diskHolder(diskPaths: [Self.bootDisk], vmID: Self.vmID, processes: []) == nil,
        )
    }

    @Test func `self holder wins even when foreign appears first`() {
        let foreign: QEMUArgv.ProcessEntry = (
            pid: 501,
            arguments: Self.fixture,
        )
        let own: QEMUArgv.ProcessEntry = (
            pid: 502,
            arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-name", "test-raw",
                "-uuid", Self.vmID.lowercased(),
                "-drive", "file=/var/lib/barkvisor/disks/additional.qcow2,format=qcow2",
            ],
        )
        #expect(
            QEMUArgv.diskHolder(
                diskPaths: [Self.bootDisk, "/var/lib/barkvisor/disks/additional.qcow2"],
                vmID: Self.vmID,
                processes: [foreign, own],
            ) == .selfProcess(pid: 502),
        )
    }
}
