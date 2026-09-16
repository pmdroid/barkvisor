import Foundation
import GRDB
import Testing
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
@testable import BarkVisorCore

#if !os(Windows)

    private final class QMPTestServer: @unchecked Sendable {
        let path: String
        private let listenFD: Int32
        private let greetsWithQMP: Bool
        private let lock = NSLock()
        private var scripted: [String: [[String: Any]]] = [:]
        private var executed: [String] = []
        private var lastArguments: [String: [String: Any]] = [:]
        private var stopped = false

        init(path: String, greetsWithQMP: Bool) throws {
            self.path = path
            self.greetsWithQMP = greetsWithQMP
            try PlatformSocket.ensureStarted()
            try? FileManager.default.removeItem(atPath: path)
            let fd = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard fd >= 0 else { throw BarkVisorError.monitorError("fixture socket failed") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(PlatformSocket.unixFamily)
            let pathBytes = path.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                throw BarkVisorError.monitorError("fixture socket path too long")
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                    pathBytes.withUnsafeBufferPointer { src in
                        if let base = src.baseAddress {
                            _ = memcpy(dst, base, src.count)
                        }
                    }
                }
            }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Foundation.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Foundation.listen(fd, 16) == 0 else {
                close(fd)
                throw BarkVisorError.monitorError("fixture bind/listen failed")
            }
            var poll = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &poll, socklen_t(MemoryLayout<timeval>.size))
            listenFD = fd
        }

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock()
                    let stopped = self.stopped
                    lock.unlock()
                    if stopped { break }
                    let conn = accept(self.listenFD, nil, nil)
                    if conn >= 0 {
                        self.serve(conn)
                        continue
                    }
                    if errno != EWOULDBLOCK, errno != EAGAIN { break }
                }
            }
        }

        func script(_ command: String, _ replies: [[String: Any]]) {
            lock.lock()
            scripted[command, default: []].append(contentsOf: replies)
            lock.unlock()
        }

        func hasExecuted(_ command: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return executed.contains(command)
        }

        func arguments(for command: String) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return lastArguments[command]
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            close(listenFD)
            try? FileManager.default.removeItem(atPath: path)
        }

        private func dequeueReply(for command: String, arguments: [String: Any]?) -> [[String: Any]]? {
            lock.lock()
            defer { lock.unlock() }
            executed.append(command)
            if let arguments { lastArguments[command] = arguments }
            guard let queued = scripted[command], !queued.isEmpty else { return nil }
            scripted[command] = nil
            return queued
        }

        private func serve(_ conn: Int32) {
            defer { close(conn) }
            if greetsWithQMP {
                writeJSON(
                    [
                        "QMP": [
                            "version": ["qemu": ["major": 8, "minor": 0, "micro": 0], "package": ""],
                            "capabilities": [Any](),
                        ],
                    ],
                    to: conn,
                )
            }
            var buffer = Data()
            let chunkSize = 8_192
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            while true {
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<nl])
                    buffer.removeSubrange(...nl)
                    if line.isEmpty { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let command = obj["execute"] as? String
                    else { continue }
                    let args = obj["arguments"] as? [String: Any]
                    if command == "qmp_capabilities" {
                        writeJSON(["return": [String: Any]()], to: conn)
                        continue
                    }
                    if command == "guest-sync", let id = args?["id"] {
                        writeJSON(["return": id], to: conn)
                        continue
                    }
                    guard let replies = dequeueReply(for: command, arguments: args) else { return }
                    for reply in replies {
                        writeJSON(reply, to: conn)
                    }
                }
                let n = read(conn, chunk, chunkSize)
                if n <= 0 { return }
                buffer.append(chunk, count: n)
            }
        }

        private func writeJSON(_ object: [String: Any], to conn: Int32) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            let msg = data + Data([0x0A])
            _ = msg.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return 0 }
                var written = 0
                while written < buf.count {
                    let n = write(conn, base + written, buf.count - written)
                    if n <= 0 { break }
                    written += n
                }
                return written
            }
        }
    }

    private func waitUntilQMP(
        _ predicate: @escaping @Sendable () async -> Bool,
        nanoseconds: UInt64 = 2_000_000_000,
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds
        while await !predicate() {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                throw BarkVisorError.timeout("qmp fixture seam")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Suite("QMPClient")
    struct QMPClientTests {
        private func makeServer(name: String, greetsWithQMP: Bool) throws -> QMPTestServer {
            let dir = FileManager.default.temporaryDirectory
            let path = dir.appendingPathComponent("bv\(name)-\(UUID().uuidString.prefix(8))sock").path
            let server = try QMPTestServer(path: path, greetsWithQMP: greetsWithQMP)
            server.start()
            return server
        }

        private func connectedClient(to server: QMPTestServer) throws -> QMPClient {
            let client = QMPClient(socketPath: server.path)
            try client.connect()
            return client
        }

        @Test func `error reply throws with class and desc`() throws {
            let server = try makeServer(name: "err", greetsWithQMP: true)
            defer { server.stop() }
            server.script(
                "query-status",
                [["error": ["class": "GenericError", "desc": "Device 'virtio0' not found"]]],
            )
            let client = try connectedClient(to: server)
            defer { client.disconnect() }
            let error = #expect(throws: BarkVisorError.self) {
                _ = try client.execute("query-status")
            }
            #expect(error?.code == "monitor_error")
            #expect(error?.errorDescription?.contains("GenericError") == true)
            #expect(error?.errorDescription?.contains("Device 'virtio0' not found") == true)
        }

        @Test func `executeWithArgs throws on error reply`() throws {
            let server = try makeServer(name: "errargs", greetsWithQMP: true)
            defer { server.stop() }
            server.script(
                "block_resize",
                [["error": ["class": "DeviceNotFound", "desc": "Device 'boot0' not found"]]],
            )
            let client = try connectedClient(to: server)
            defer { client.disconnect() }
            let error = #expect(throws: BarkVisorError.self) {
                _ = try client.executeWithArgs("block_resize", args: ["device": "boot0", "size": 128])
            }
            #expect(error?.errorDescription?.contains("DeviceNotFound") == true)
            #expect(error?.errorDescription?.contains("Device 'boot0' not found") == true)
            #expect(server.hasExecuted("block_resize"))
            #expect(server.arguments(for: "block_resize")?["device"] as? String == "boot0")
        }

        @Test func `error without class and desc still throws`() throws {
            let server = try makeServer(name: "errbare", greetsWithQMP: true)
            defer { server.stop() }
            server.script("query-status", [["error": ["mystery": true]]])
            let client = try connectedClient(to: server)
            defer { client.disconnect() }
            let error = #expect(throws: BarkVisorError.self) {
                _ = try client.execute("query-status")
            }
            #expect(error?.errorDescription?.contains("mystery") == true)
        }

        @Test func `interleaved events skipped before return`() throws {
            let server = try makeServer(name: "evt", greetsWithQMP: true)
            defer { server.stop() }
            server.script(
                "query-status",
                [
                    ["event": "RESET", "timestamp": ["seconds": 1, "microseconds": 0]],
                    ["return": ["status": "running"]],
                ],
            )
            let client = try connectedClient(to: server)
            defer { client.disconnect() }
            let response = try client.execute("query-status")
            #expect(response["event"] == nil)
            #expect(response["return"] as? [String: Any] != nil)
        }

        @Test func `denied guest-shutdown error reply is not swallowed`() throws {
            let server = try makeServer(name: "gaden", greetsWithQMP: false)
            defer { server.stop() }
            server.script(
                "guest-shutdown",
                [["error": ["class": "GenericError", "desc": "The agent is blacklisted"]]],
            )
            let error = #expect(throws: BarkVisorError.self) {
                try GuestAgentChannel.shutdown(socketPath: server.path)
            }
            #expect(error?.errorDescription?.contains("GenericError") == true)
            #expect(error?.errorDescription?.contains("blacklisted") == true)
            #expect(server.hasExecuted("guest-shutdown"))
        }

        @Test func `rejected online resize throws and stored size unchanged`() async throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
                "bvresize-\(UUID().uuidString.prefix(8))",
            )
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            let vmID = "vm-resize-test"
            try await pool.write { db in
                try Disk(
                    id: "d1",
                    name: "boot",
                    path: tmp.appendingPathComponent("d1.qcow2").path,
                    sizeBytes: 1_073_741_824,
                    format: "qcow2",
                    vmId: vmID,
                    autoCreated: false,
                    status: "ready",
                    createdAt: "2026-09-15T00:00:00Z",
                ).insert(db)
                try VM(
                    id: vmID, name: "resizer", vmType: "linux-arm64", state: "running",
                    cpuCount: 1, memoryMb: 1_024,
                    bootDiskId: "d1", networkId: nil,
                    cloudInitPath: nil, description: nil, bootOrder: "cd",
                    displayResolution: "1280x800", additionalDiskIds: nil, uefi: false,
                    tpmEnabled: false, macAddress: nil, sharedPaths: nil,
                    portForwards: nil, autoCreated: false, pendingChanges: false,
                    createdAt: "2026-09-15T00:00:00Z", updatedAt: "2026-09-15T00:00:00Z",
                ).insert(db)
            }
            let server = try QMPTestServer(
                path: tmp.appendingPathComponent("vm-resize-test-qmp.sock").path,
                greetsWithQMP: true,
            )
            server.start()
            defer { server.stop() }
            server.script(
                "block_resize",
                [["error": ["class": "GenericError", "desc": "Device 'boot0' is not writable"]]],
            )
            let manager = VMManager(dbPool: pool)
            let argv = try #require(QEMUArgv(arguments: [
                "/usr/bin/qemu-system-x86_64",
                "-uuid", vmID,
                "-qmp", "unix:\(server.path),server=on,wait=off",
            ]))
            try await manager.adoptRunningProcess(
                vmID: vmID,
                pid: getpid(),
                argv: argv,
                previousPids: nil,
            )
            let disk = try await pool.read { db in try Disk.fetchOne(db, key: "d1") }
            let qmpDisk = QMPDiskService(vmManager: manager, dbPool: pool)
            let error = await #expect(throws: BarkVisorError.self) {
                try await qmpDisk.resizeDisk(vmID: vmID, disk: #require(disk), sizeBytes: 2_147_483_648)
            }
            #expect(error?.errorDescription?.contains("GenericError") == true)
            #expect(error?.errorDescription?.contains("Device 'boot0' is not writable") == true)
            #expect(server.arguments(for: "block_resize")?["device"] as? String == "boot0")
            let stored = try await pool.read { db in try Disk.fetchOne(db, key: "d1") }
            #expect(stored?.sizeBytes == 1_073_741_824)
        }

        @Test func `denied guest-shutdown falls back to acpi immediately`() async throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
                "bvgafb-\(UUID().uuidString.prefix(8))",
            )
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let vmID = "vm-gafb-fallback"
            let shortID = String(vmID.prefix(12))
            let qmpServer = try QMPTestServer(
                path: tmp.appendingPathComponent("\(shortID)-qmp.sock").path,
                greetsWithQMP: true,
            )
            qmpServer.start()
            defer { qmpServer.stop() }
            let gaServer = try QMPTestServer(
                path: tmp.appendingPathComponent("\(shortID)-ga.sock").path,
                greetsWithQMP: false,
            )
            gaServer.start()
            defer { gaServer.stop() }
            gaServer.script(
                "guest-shutdown",
                [["error": ["class": "GenericError", "desc": "The agent is blacklisted"]]],
            )
            qmpServer.script("system_powerdown", [["return": [String: Any]()]])

            let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            let manager = VMManager(dbPool: pool)
            let running = RunningVM(
                process: nil, pid: getpid(),
                serialSocketPath: "", vncSocketPath: "",
                qmpSocketPath: qmpServer.path, qmpEventSocketPath: "",
                swtpmProcess: nil, reconnected: true,
            )
            let method = try await manager.requestGracefulShutdown(running: running, vmID: vmID)
            #expect(method == "acpi-powerdown")
            #expect(gaServer.hasExecuted("guest-shutdown"))
            #expect(qmpServer.hasExecuted("system_powerdown"))
            await #expect(throws: Never.self) {
                try await waitUntilQMP { qmpServer.hasExecuted("system_powerdown") }
            }
        }
    }

#endif
