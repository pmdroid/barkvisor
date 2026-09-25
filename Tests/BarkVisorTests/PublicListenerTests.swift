import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing
@testable import BarkVisorCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct PublicListenerTests {
    @Test func `bark server accepts http and device tls while the daemon stays on the socket`() async throws {
        #if os(Windows)
            return
        #else
            let uid = WorkloadPrivilegeDrop.currentEUID()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("bv-pub-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let path = directory.appendingPathComponent("s").path
            let driver = RecordingWorkloadSocketDriver()
            let session = LocalManagementSession(
                policy: LocalManagementPolicy(
                    allowedPeerUIDs: [uid],
                    memberships: [
                        MembershipFact(subject: "device-a", sessionToken: "token-a", revoked: false),
                    ],
                    resources: ResourcePolicy(allowedRoots: [], allowedMounts: [], allowedDevices: []),
                ),
                operationStore: MemoryOperationStore(),
                workloadDriver: driver,
            )
            let daemon = LocalManagementSocketServer(
                path: path,
                session: session,
                directoryMode: 0o700,
                socketMode: 0o600,
            )
            let daemonTask = Task { try await daemon.run() }
            let server = PublicBarkServer(socketPath: path)
            let serverTask = Task { try await server.run() }
            defer {
                server.stop()
                daemon.stop()
            }
            for _ in 0 ..< 50 {
                if FileManager.default.fileExists(atPath: path), server.httpPort != nil, server.deviceTLSPort != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let http = try #require(server.httpPort)
            let tls = try #require(server.deviceTLSPort)
            #expect(server.bindsPublicHTTP)
            #expect(server.bindsDeviceTLS)
            #expect(!daemon.bindsTCP)
            let serverPlan = ListenerPlan.forRole(.barkServer)
            let daemonPlan = ListenerPlan.forRole(.barkDaemon)
            #expect(serverPlan.publicHTTP)
            #expect(serverPlan.deviceTLS)
            #expect(!serverPlan.managementListen)
            #expect(!daemonPlan.publicHTTP)
            #expect(!daemonPlan.deviceTLS)
            #expect(!daemonPlan.tcpManagement)
            #expect(!VaporListenerGate.authoritativeStartAllowed(role: .barkServer))
            #expect(!VaporListenerGate.authoritativeStartAllowed(role: .barkDaemon))
            #expect(VaporListenerGate.authoritativeStartAllowed(role: .combined))
            let started = try httpExchange(
                port: http,
                request: """
                POST /api/vms/vm-1/start HTTP/1.1\r
                Host: 127.0.0.1\r
                X-Bark-Session: token-a\r
                X-Bark-Operation: op-public\r
                X-Bark-User: device-a\r
                \r
                """,
            )
            #expect(started.contains("200"))
            #expect(started.contains("running"))
            let again = try httpExchange(
                port: http,
                request: """
                POST /api/vms/vm-1/start HTTP/1.1\r
                Host: 127.0.0.1\r
                X-Bark-Session: token-a\r
                X-Bark-Operation: op-public\r
                \r
                """,
            )
            #expect(again.contains("running"))
            #expect(driver.calls.count == 1)
            let forged = try httpExchange(
                port: http,
                request: """
                POST /api/vms/vm-1/stop HTTP/1.1\r
                Host: 127.0.0.1\r
                X-Bark-User: admin\r
                X-Bark-Operation: op-forged\r
                \r
                """,
            )
            #expect(forged.contains("403"))
            #expect(forged.contains("forgedIdentity"))
            #expect(driver.calls.count == 1)
            let events = try httpExchange(
                port: http,
                request: """
                GET /api/vms/vm-1/events HTTP/1.1\r
                Host: 127.0.0.1\r
                Upgrade: websocket\r
                X-Bark-Session: token-a\r
                \r
                """,
            )
            #expect(events.contains("101"))
            #expect(events.contains("running"))
            let banner = try await tlsBanner(port: tls)
            #expect(banner == "barkvisor-device")
            server.stop()
            daemon.stop()
            _ = try? await serverTask.value
            _ = try? await daemonTask.value
        #endif
    }
}

#if !os(Windows)
    private func httpExchange(port: Int, request: String) throws -> String {
        let fd = socket(AF_INET, PlatformSocket.stream, 0)
        guard fd >= 0 else { throw LocalManagementError.unavailable }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 { throw LocalManagementError.connectionLost }
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var remaining = Data(request.utf8)
        while !remaining.isEmpty {
            let wrote = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                #if canImport(Darwin)
                    return Darwin.write(fd, base, raw.count)
                #else
                    return Glibc.write(fd, base, raw.count)
                #endif
            }
            if wrote <= 0 { throw LocalManagementError.connectionLost }
            remaining.removeFirst(wrote)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        if poll(&pollFD, 1, 2_000) <= 0 { throw LocalManagementError.connectionLost }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        return String(decoding: data, as: UTF8.self)
    }

    private func tlsBanner(port: Int) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        let context = try NIOSSLContext(configuration: tls)
        let box = TLSTextBox()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(2))
            .channelInitializer { channel in
                do {
                    let handler = try NIOSSLClientHandler(context: context, serverHostname: "localhost")
                    return channel.pipeline.addHandler(handler).flatMap {
                        channel.pipeline.addHandler(TLSTextHandler(box: box))
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
        defer { Task { try? await channel.close() } }
        for _ in 0 ..< 20 {
            if let text = box.text { return text }
            try await Task.sleep(for: .milliseconds(20))
        }
        return box.text ?? ""
    }

    private final class TLSTextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var text: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ text: String) {
            lock.lock()
            stored = text
            lock.unlock()
        }
    }

    private final class TLSTextHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let box: TLSTextBox
        init(box: TLSTextBox) {
            self.box = box
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if let text = buffer.readString(length: buffer.readableBytes) {
                box.set(text)
            }
        }
    }
#endif
