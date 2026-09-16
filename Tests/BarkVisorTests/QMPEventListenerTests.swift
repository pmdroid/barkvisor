import Dispatch
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
    private let qmpGreetingLine =
        "{\"QMP\":{\"version\":{\"qemu\":{\"major\":8,\"minor\":0,\"micro\":0},\"package\":\"\"},\"capabilities\":[]}}\n"

    private let qmpPanicEvent =
        "{\"event\":\"GUEST_PANICKED\",\"data\":{\"action\":\"pause\"},\"timestamp\":{\"seconds\":1,\"microseconds\":0}}\n"

    private let qmpResetEvent =
        "{\"event\":\"RESET\",\"timestamp\":{\"seconds\":1,\"microseconds\":0}}\n"

    private let qmpBlockIOEvent =
        "{\"event\":\"BLOCK_IO_ERROR\",\"data\":{\"device\":\"virtio0\",\"operation\":\"write\",\"action\":\"report\"},\"timestamp\":{\"seconds\":1,\"microseconds\":0}}\n"

    private let qmpGuestShutdownEvent =
        "{\"event\":\"SHUTDOWN\",\"data\":{\"guest\":true,\"reason\":\"guest-shutdown\"},\"timestamp\":{\"seconds\":1,\"microseconds\":0}}\n"

    private let qmpHandshakeNanos: UInt64 = 5_000_000_000

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool,
        nanoseconds: UInt64 = 2_000_000_000,
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds
        while await !predicate() {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                throw BarkVisorError.timeout("qmp fixture")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func qmpTestState(of vmID: String, db: DatabasePool) async throws -> String? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM vms WHERE id = ?", arguments: [vmID])
        }
    }

    private func qmpInsertVM(_ vmID: String, db: DatabasePool, state: String = "running") async throws {
        try await db.write { db in
            try Disk(
                id: "disk-\(vmID)",
                name: "boot",
                path: "/tmp/\(vmID).qcow2",
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: nil,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-08-19T00:00:00Z",
            ).insert(db)
            try VM(
                id: vmID, name: "qmp-\(vmID)", vmType: "linux-arm64", state: state,
                cpuCount: 2, memoryMb: 1_024,
                bootDiskId: "disk-\(vmID)", networkId: nil,
                cloudInitPath: nil, description: nil, bootOrder: "cd",
                displayResolution: "1280x800", additionalDiskIds: nil, uefi: true,
                tpmEnabled: false, macAddress: nil, sharedPaths: nil,
                portForwards: nil, autoCreated: false, pendingChanges: false,
                createdAt: "2026-08-19T00:00:00Z", updatedAt: "2026-08-19T00:00:00Z",
            ).insert(db)
        }
    }

    private func qmpMakeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private final class QMPEventFixture: @unchecked Sendable {
        let path: String
        private let listenFD: Int32
        private let lock = NSLock()
        private var started = false
        private var acceptedFD: Int32 = -1
        private var didHandshake = false
        private var didPeerClose = false
        private var receivedCommandLine: String?

        init(dir: URL, name: String) throws {
            let path = dir.appendingPathComponent(name).path
            self.path = path
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            try PlatformSocket.ensureStarted()
            let server = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
            guard server >= 0 else {
                throw BarkVisorError.badRequest("fixture socket")
            }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(PlatformSocket.unixFamily)
            let pathBytes = path.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                close(server)
                throw BarkVisorError.badRequest("fixture socket path too long")
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                    pathBytes.withUnsafeBufferPointer { src in
                        if let base = src.baseAddress {
                            _ = memcpy(dest, base, src.count)
                        }
                    }
                }
            }
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(server, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0, listen(server, 4) == 0 else {
                close(server)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                throw BarkVisorError.badRequest("fixture bind")
            }
            listenFD = server
        }

        func begin() {
            lock.lock()
            guard !started else {
                lock.unlock()
                return
            }
            started = true
            lock.unlock()
            let ready = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                ready.signal()
                let client = accept(self.listenFD, nil, nil)
                guard client >= 0 else { return }
                self.noteAccepted(client)
                self.writeLine(qmpGreetingLine, to: client)
                guard let line = self.readCommandLine(from: client) else {
                    self.markPeerClosed()
                    return
                }
                self.noteHandshake(line)
                self.writeLine("{\"return\":{}}\n", to: client)
                while true {
                    let chunkSize = 4_096
                    let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
                    let n = read(client, chunk, chunkSize)
                    chunk.deallocate()
                    if n <= 0 { break }
                }
                self.markPeerClosed()
            }
            ready.wait()
        }

        func sendEvent(_ line: String) {
            lock.lock()
            let fd = acceptedFD
            lock.unlock()
            guard fd >= 0 else { return }
            writeLine(line, to: fd)
        }

        var handshakeDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didHandshake
        }

        var peerClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didPeerClose
        }

        var commandLine: String? {
            lock.lock()
            defer { lock.unlock() }
            return receivedCommandLine
        }

        func shutdown() {
            lock.lock()
            let fd = acceptedFD
            acceptedFD = -1
            lock.unlock()
            if fd >= 0 { close(fd) }
            close(listenFD)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }

        private func markPeerClosed() {
            lock.lock()
            didPeerClose = true
            lock.unlock()
        }

        private func noteAccepted(_ fd: Int32) {
            lock.lock()
            acceptedFD = fd
            lock.unlock()
        }

        private func noteHandshake(_ line: String) {
            lock.lock()
            receivedCommandLine = line
            didHandshake = true
            lock.unlock()
        }

        private func readCommandLine(from fd: Int32) -> String? {
            let chunkSize = 4_096
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            var buffer = Data()
            while true {
                let n = read(fd, chunk, chunkSize)
                if n <= 0 { return nil }
                buffer.append(chunk, count: n)
                if buffer.firstIndex(of: 0x0A) != nil {
                    return String(data: buffer, encoding: .utf8)
                }
            }
        }

        private func writeLine(_ text: String, to fd: Int32) {
            let bytes = Array(text.utf8CString).filter { $0 != 0 }
            bytes.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                var written = 0
                while written < buf.count {
                    let n = send(fd, base + written, buf.count - written, MSG_NOSIGNAL)
                    if n <= 0 { return }
                    written += n
                }
            }
        }
    }

    @Suite("QMPEventListener", .serialized)
    struct QMPEventListenerTests {
        @Test func `guest panic lands in db well under the socket timeout`() async throws {
            let dir = try qmpMakeTempDir()
            let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            try await qmpInsertVM("vm-panic", db: pool)
            let listener = QMPEventListener(dbPool: pool)
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = VMManager(dbPool: pool)
            await listener.setVMManager(manager)

            do {
                let fixture = try QMPEventFixture(dir: dir, name: "panic.sock")
                defer { fixture.shutdown() }
                fixture.begin()
                await listener.start(vmID: "vm-panic", eventSocketPath: fixture.path)
                try await waitUntil({ fixture.handshakeDone }, nanoseconds: qmpHandshakeNanos)

                fixture.sendEvent(qmpPanicEvent)

                try await waitUntil {
                    let state = try? await qmpTestState(of: "vm-panic", db: pool)
                    return state == "error"
                }
                try await waitUntil {
                    await manager.healthError(for: "vm-panic") == "Kernel panic"
                }
                let health = await manager.healthError(for: "vm-panic")
                #expect(health == "Kernel panic")
                #expect(!fixture.peerClosed)
                await listener.stopAll()
            } catch {
                await listener.stopAll()
                throw error
            }
        }

        @Test func `streamed events are applied as they arrive without disconnect`() async throws {
            let dir = try qmpMakeTempDir()
            let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            try await qmpInsertVM("vm-stream", db: pool)
            let listener = QMPEventListener(dbPool: pool)
            defer { try? FileManager.default.removeItem(at: dir) }

            do {
                let fixture = try QMPEventFixture(dir: dir, name: "stream.sock")
                defer { fixture.shutdown() }
                fixture.begin()
                await listener.start(vmID: "vm-stream", eventSocketPath: fixture.path)
                try await waitUntil({ fixture.handshakeDone }, nanoseconds: qmpHandshakeNanos)

                fixture.sendEvent(qmpPanicEvent)
                fixture.sendEvent(qmpResetEvent)
                fixture.sendEvent(qmpBlockIOEvent)

                try await waitUntil {
                    let state = try? await qmpTestState(of: "vm-stream", db: pool)
                    return state == "error"
                }
                try await waitUntil {
                    let entries = try? await AuditService.vmEvents(vmID: "vm-stream", db: pool)
                    return entries?.contains { entry in
                        entry.detail?.contains("block io error") == true
                    } ?? false
                }
                #expect(!fixture.peerClosed)
                await listener.stopAll()
            } catch {
                await listener.stopAll()
                throw error
            }
        }

        @Test func `events on a stopped run cannot poison the restarted run`() async throws {
            let dir = try qmpMakeTempDir()
            let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            try await qmpInsertVM("vm-stale", db: pool)
            let listener = QMPEventListener(dbPool: pool)
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = VMManager(dbPool: pool)
            await listener.setVMManager(manager)

            do {
                let oldSocket = try QMPEventFixture(dir: dir, name: "old.sock")
                defer { oldSocket.shutdown() }
                let newSocket = try QMPEventFixture(dir: dir, name: "new.sock")
                defer { newSocket.shutdown() }
                let commandSocket = try QMPEventFixture(dir: dir, name: "cmd.sock")
                defer { commandSocket.shutdown() }
                commandSocket.begin()

                let running = RunningVM(
                    process: nil,
                    pid: 4_242,
                    serialSocketPath: dir.appendingPathComponent("serial.sock").path,
                    vncSocketPath: dir.appendingPathComponent("vnc.sock").path,
                    qmpSocketPath: commandSocket.path,
                    qmpEventSocketPath: newSocket.path,
                    swtpmProcess: nil,
                    reconnected: true,
                )
                await manager.registerReconnectedVM(vmID: "vm-stale", running: running)

                oldSocket.begin()
                await listener.start(vmID: "vm-stale", eventSocketPath: oldSocket.path)
                try await waitUntil({ oldSocket.handshakeDone }, nanoseconds: qmpHandshakeNanos)

                await listener.stop(vmID: "vm-stale")

                newSocket.begin()
                await listener.start(vmID: "vm-stale", eventSocketPath: newSocket.path)
                try await waitUntil({ newSocket.handshakeDone }, nanoseconds: qmpHandshakeNanos)
                try await pool.write { db in
                    try db.execute(
                        sql: "UPDATE vms SET state = 'running', updatedAt = ? WHERE id = ?",
                        arguments: [iso8601.string(from: Date()), "vm-stale"],
                    )
                }

                oldSocket.sendEvent(qmpPanicEvent)
                oldSocket.sendEvent(qmpGuestShutdownEvent)
                try await Task.sleep(nanoseconds: 400_000_000)

                let state = try await qmpTestState(of: "vm-stale", db: pool)
                #expect(state == "running")
                #expect(commandSocket.commandLine == nil)
                let health = await manager.healthError(for: "vm-stale")
                #expect(health == nil)

                newSocket.sendEvent(qmpResetEvent)
                let stateAfter = try await qmpTestState(of: "vm-stale", db: pool)
                #expect(stateAfter == "running")
                await listener.stopAll()
            } catch {
                await listener.stopAll()
                throw error
            }
        }

        @Test func `stop closes the live event socket promptly`() async throws {
            let dir = try qmpMakeTempDir()
            let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            try await qmpInsertVM("vm-stop", db: pool)
            let listener = QMPEventListener(dbPool: pool)
            defer { try? FileManager.default.removeItem(at: dir) }

            do {
                let fixture = try QMPEventFixture(dir: dir, name: "stop.sock")
                defer { fixture.shutdown() }
                fixture.begin()
                await listener.start(vmID: "vm-stop", eventSocketPath: fixture.path)
                try await waitUntil({ fixture.handshakeDone }, nanoseconds: qmpHandshakeNanos)

                await listener.stop(vmID: "vm-stop")
                try await waitUntil { fixture.peerClosed }
                await listener.stopAll()
            } catch {
                await listener.stopAll()
                throw error
            }
        }

        @Test func `stopAll closes every reader`() async throws {
            let dir = try qmpMakeTempDir()
            let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
            try AppDatabase.makeMigrator().migrate(pool)
            try await qmpInsertVM("vm-a", db: pool)
            try await qmpInsertVM("vm-b", db: pool)
            let listener = QMPEventListener(dbPool: pool)
            defer { try? FileManager.default.removeItem(at: dir) }

            do {
                let fixtureA = try QMPEventFixture(dir: dir, name: "a.sock")
                defer { fixtureA.shutdown() }
                let fixtureB = try QMPEventFixture(dir: dir, name: "b.sock")
                defer { fixtureB.shutdown() }
                fixtureA.begin()
                fixtureB.begin()
                await listener.start(vmID: "vm-a", eventSocketPath: fixtureA.path)
                await listener.start(vmID: "vm-b", eventSocketPath: fixtureB.path)
                try await waitUntil(
                    { fixtureA.handshakeDone && fixtureB.handshakeDone },
                    nanoseconds: qmpHandshakeNanos,
                )

                await listener.stopAll()
                try await waitUntil {
                    fixtureA.peerClosed && fixtureB.peerClosed
                }
            } catch {
                await listener.stopAll()
                throw error
            }
        }
    }
#endif
