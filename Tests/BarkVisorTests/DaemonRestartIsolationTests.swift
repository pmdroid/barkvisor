import Foundation
import GRDB
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
        #expect(text.contains("User=root"))
        #expect(!text.contains("User=barkvisor"))
        #expect(text.contains("BARKVISOR_SOCKET_DIR=/var/run/barkvisor"))
        #expect(text.contains("RuntimeDirectory=barkvisor"))
        #expect(text.contains("RuntimeDirectoryPreserve=yes"))
        #expect(text.contains("SupplementaryGroups=kvm"))
        #expect(!text.contains("SupplementaryGroups=kvm disk"))
        #expect(!text.contains("KillMode=control-group"))
        let packaged = try Self.readRepoFile("packaging/linux/barkvisor.service")
        #expect(packaged.contains("KillMode=process"))
        #expect(packaged.contains("User=root"))
        #expect(!packaged.contains("User=barkvisor"))
        #expect(packaged.contains("BARKVISOR_SOCKET_DIR=/var/run/barkvisor"))
        #expect(packaged.contains("RuntimeDirectory=barkvisor"))
        #expect(packaged.contains("RuntimeDirectoryPreserve=yes"))
        #expect(packaged.contains("SupplementaryGroups=kvm"))
        #expect(!packaged.contains("SupplementaryGroups=kvm disk"))
        let postinst = try Self.readRepoFile("packaging/linux/debian/postinst")
        #expect(postinst.contains("usermod -aG disk barkvisor"))
        #expect(postinst.contains("barkvisor.service barkvisor-agent.service"))
        #expect(postinst.contains("${unit}.d/disk.conf"))
        #expect(postinst.contains("SupplementaryGroups=disk"))
        #expect(postinst.contains("try-restart barkvisor.service"))
        #expect(postinst.contains("try-restart barkvisor-agent.service"))
        let agent = try Self.readRepoFile("packaging/linux/barkvisor-agent.service")
        #expect(agent.contains("KillMode=process"))
        #expect(agent.contains("RuntimeDirectoryPreserve=yes"))
        #expect(!agent.contains("KillMode=control-group"))
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

    @Test func `adopt persists running state and rewrites the pidfile`() async throws {
        let (pool, vmID) = try await Self.makeVMWithPool(state: "error")
        let manager = VMManager(dbPool: pool)
        let pid = ProcessInfo.processInfo.processIdentifier
        let argv = try #require(QEMUArgv(arguments: Self.fixtureArgv(vmID: vmID)))
        let previous = VMPidFile(qemuPid: 1, swtpmPid: 2, codingAgentHostPort: 24_981)

        try await manager.adoptRunningProcess(vmID: vmID, pid: pid, argv: argv, previousPids: previous)
        defer { Task { await CodingAgentSessionStore.shared.remove(vmID: vmID) } }

        #expect(await manager.isRunning(vmID))
        #expect(await manager.healthError(for: vmID) == nil)
        let state = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM vms WHERE id = ?", arguments: [vmID])
        }
        #expect(state == "running")
        let pidsDir = await manager.pidsDir
        let rewritten = VMManager.readPidFile(pidsDir: pidsDir, vmID: vmID)
        #expect(rewritten?.qemuPid == pid)
        #expect(rewritten?.codingAgentHostPort == 24_981)
    }

    @Test func `preflight adopts a self holder from injected processes`() async throws {
        let (pool, vmID) = try await Self.makeVMWithPool(state: "stopped")
        let manager = VMManager(dbPool: pool)
        let pid = ProcessInfo.processInfo.processIdentifier

        let adopted = try await manager.adoptExistingQEMUOrConflict(
            vmID: vmID,
            vmName: "test-raw",
            diskPaths: ["/var/lib/barkvisor/disks/\(vmID).qcow2"],
            processes: [Self.selfHolderEntry(vmID: vmID, pid: pid)],
        )

        #expect(adopted)
        #expect(await manager.isRunning(vmID))
        let state = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM vms WHERE id = ?", arguments: [vmID])
        }
        #expect(state == "running")
    }

    @Test func `preflight throws conflict naming foreign holder`() async throws {
        let pool = try Self.makePool()
        let manager = VMManager(dbPool: pool)
        let vmID = UUID().uuidString.uppercased()
        let lockedDisk = "/var/lib/barkvisor/disks/85E9313A-17B3-406B-9056-2818AE6AC177.qcow2"

        do {
            try await manager.adoptExistingQEMUOrConflict(
                vmID: vmID,
                vmName: "test-raw",
                diskPaths: [lockedDisk],
                processes: [Self.foreignHolderEntry],
            )
            Issue.record("expected conflict")
        } catch let error as BarkVisorError {
            guard case let .conflict(message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(message.contains("202"))
            #expect(message.contains("test-raw"))
        }
    }

    @Test func `preflight does not adopt a live non qemu pidfile`() async throws {
        let (pool, vmID) = try await Self.makeVMWithPool(state: "stopped")
        let manager = VMManager(dbPool: pool)
        let pidsDir = await manager.pidsDir
        try FileManager.default.createDirectory(at: pidsDir, withIntermediateDirectories: true)
        let live = ProcessInfo.processInfo.processIdentifier
        try VMPidFile(qemuPid: live, swtpmPid: nil).serialized()
            .write(to: pidsDir.appendingPathComponent("\(vmID).pid"), atomically: true, encoding: .utf8)

        let adopted = try await manager.adoptExistingQEMUOrConflict(
            vmID: vmID,
            vmName: "test-raw",
            diskPaths: ["/var/lib/barkvisor/disks/\(vmID).qcow2"],
            processes: [],
        )
        #expect(!adopted)
        #expect(await manager.isRunning(vmID) == false)
    }

    @Test func `preflight proceeds to spawn when no holder exists`() async throws {
        let pool = try Self.makePool()
        let manager = VMManager(dbPool: pool)
        let unrelated: QEMUArgv.ProcessEntry = (
            pid: 404,
            arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-uuid", "EEEEEEEE-0000-0000-0000-000000000000",
                "-drive", "file=/var/lib/barkvisor/disks/some-other-disk.qcow2,format=qcow2",
            ],
        )
        let adopted = try await manager.adoptExistingQEMUOrConflict(
            vmID: UUID().uuidString.uppercased(),
            vmName: "test-raw",
            diskPaths: ["/var/lib/barkvisor/disks/mine.qcow2"],
            processes: [unrelated],
        )
        #expect(!adopted)
    }

    private static func makePool() throws -> DatabasePool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkvisor-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return pool
    }

    private static func makeVMWithPool(state: String) async throws -> (DatabasePool, String) {
        let pool = try makePool()
        let vmID = UUID().uuidString.uppercased()
        let diskID = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            try Disk(
                id: diskID,
                name: "boot",
                path: "/var/lib/barkvisor/disks/\(vmID).qcow2",
                sizeBytes: 1_024,
                format: "qcow2",
                vmId: vmID,
                autoCreated: false,
                status: "ready",
                createdAt: now,
            ).insert(db)
            try VM(
                id: vmID,
                name: "test-raw",
                vmType: GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch),
                state: state,
                cpuCount: 1,
                memoryMb: 512,
                bootDiskId: diskID,
                isoIds: nil,
                networkId: nil,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "c",
                displayResolution: nil,
                additionalDiskIds: nil,
                uefi: false,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: nil,
                usbDevices: nil,
                autoCreated: false,
                pendingChanges: false,
                createdAt: now,
                updatedAt: now,
            ).insert(db)
        }
        return (pool, vmID)
    }

    private static func fixtureArgv(vmID: String) -> [String] {
        [
            "/usr/bin/qemu-system-x86_64",
            "-name", "test-raw",
            "-uuid", vmID,
            "-drive", "file=/var/lib/barkvisor/disks/\(vmID).qcow2,format=qcow2,id=boot0",
            "-chardev", "socket,id=serial0,path=/tmp/barkvisor-test-ser.sock,server=on,wait=off",
            "-vnc", "unix:/tmp/barkvisor-test-vnc.sock,lossy=on",
            "-qmp", "unix:/tmp/barkvisor-test-qmp.sock,server,nowait",
            "-qmp", "unix:/tmp/barkvisor-test-evt.sock,server,nowait",
        ]
    }

    private static func selfHolderEntry(vmID: String, pid: Int32) -> QEMUArgv.ProcessEntry {
        (
            pid: pid,
            arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-name", "test-raw",
                "-uuid", vmID,
                "-drive", "file=/var/lib/barkvisor/disks/\(vmID).qcow2,format=qcow2",
            ],
        )
    }

    private static let foreignHolderEntry: QEMUArgv.ProcessEntry = (
        pid: 202,
        arguments: [
            "/usr/bin/qemu-system-x86_64",
            "-name", "test-raw",
            "-uuid", "6FB33A30-F139-4DE5-80EB-1DA1883696B1",
            "-drive",
            "file=/var/lib/barkvisor/disks/85E9313A-17B3-406B-9056-2818AE6AC177.qcow2,format=qcow2",
        ],
    )

    private static func readRepoFile(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        let file = url.appendingPathComponent(relative)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
