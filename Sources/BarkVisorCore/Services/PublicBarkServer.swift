import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import X509
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public final class PublicBarkServer: @unchecked Sendable {
    public let socketPath: String
    public private(set) var httpPort: Int?
    public private(set) var deviceTLSPort: Int?
    public var bindsPublicHTTP: Bool {
        httpPort != nil
    }
    public var bindsDeviceTLS: Bool {
        deviceTLSPort != nil
    }
    private let lock = NSLock()
    private var httpFD: Int32 = -1
    private var stopped = false
    private var tlsGroup: MultiThreadedEventLoopGroup?
    private var tlsChannel: Channel?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fd = httpFD
        lock.unlock()
        if fd >= 0 {
            #if !os(Windows)
                _ = shutdown(fd, Int32(SHUT_RDWR))
            #endif
        }
        tlsChannel?.close(promise: nil)
    }

    public func run(httpPort requestedHTTP: Int = 0, deviceTLSPort requestedTLS: Int = 0) async throws {
        #if os(Windows)
            _ = requestedHTTP
            _ = requestedTLS
            throw LocalManagementError.unavailable
        #else
            let http = try PublicHTTP.bind(port: requestedHTTP)
            rememberHTTP(http.fd, port: http.port)
            defer {
                close(http.fd)
                forgetHTTP()
            }
            try await bindDeviceTLS(port: requestedTLS)
            let fd = http.fd
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread { [self] in
                    while !isStopped {
                        let client = PublicHTTP.accept(fd)
                        if client < 0 { continue }
                        serve(client)
                    }
                    shutdownTLS()
                    continuation.resume()
                }
            }
        #endif
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func rememberHTTP(_ fd: Int32, port: Int) {
        lock.lock()
        httpFD = fd
        httpPort = port
        lock.unlock()
    }

    private func forgetHTTP() {
        lock.lock()
        httpFD = -1
        lock.unlock()
    }

    private func shutdownTLS() {
        let channel = tlsChannel
        let group = tlsGroup
        channel?.close(promise: nil)
        try? group?.syncShutdownGracefully()
    }

    #if !os(Windows)
        private func bindDeviceTLS(port: Int) async throws {
            let material = try PublicTLS.material()
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            tlsGroup = group
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NIOSSLServerHandler(context: material.context)).flatMap {
                        channel.pipeline.addHandler(PublicTLSBanner())
                    }
                }
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            tlsChannel = channel
            deviceTLSPort = channel.localAddress?.port
        }

        private func serve(_ client: Int32) {
            defer { close(client) }
            guard let request = PublicHTTP.readRequest(client) else { return }
            let response = handle(request)
            PublicHTTP.write(client, response)
        }

        private func handle(_ request: PublicHTTPRequest) -> String {
            if request.upgradeWebSocket, let workload = request.workloadID {
                let events = socket(
                    name: "workload.events",
                    workloadID: workload,
                    operationID: request.operationID ?? "events-\(workload)",
                    session: request.session,
                    claim: request.claim,
                )
                let body = (events.events ?? []).joined(separator: "\n")
                return PublicHTTP.websocket(body)
            }
            guard let workload = request.workloadID, let name = request.operationName else {
                return PublicHTTP.json(status: 404, body: #"{"error":"not found"}"#)
            }
            let operationID = request.operationID ?? "\(name)-\(workload)"
            let result = socket(
                name: name,
                workloadID: workload,
                operationID: operationID,
                session: request.session,
                claim: request.claim,
            )
            if let rejection = result.rejection {
                return PublicHTTP.json(status: 403, body: #"{"rejection":"\#(rejection)"}"#)
            }
            let state = result.workloadState ?? ""
            return PublicHTTP.json(
                status: 200,
                body: #"{"operationId":"\#(result.operationId)","state":"\#(state)","phase":"\#(result.phase)"}"#,
            )
        }

        private func socket(
            name: String,
            workloadID: String,
            operationID: String,
            session: String?,
            claim: String?,
        ) -> LocalManagementResponse {
            let request = LocalManagementRequest(
                requestId: "public-\(operationID)",
                operationId: operationID,
                name: name,
                claimedUserId: claim,
                sessionToken: session,
                workloadID: workloadID,
            )
            do {
                return try LocalManagementSocketClient.exchange(path: socketPath, request: request)
            } catch {
                return LocalManagementResponse(
                    requestId: request.requestId,
                    operationId: operationID,
                    accepted: false,
                    phase: "rejected",
                    effectCount: 0,
                    rejection: LocalRejection.peerNotAllowed.rawValue,
                )
            }
        }
    #endif
}

#if !os(Windows)
    struct PublicHTTPRequest {
        var method: String
        var path: String
        var session: String?
        var claim: String?
        var operationID: String?
        var upgradeWebSocket: Bool

        var workloadID: String? {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[0] == "api", parts[1] == "vms" else { return nil }
            return parts[2]
        }

        var operationName: String? {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 4 else { return nil }
            switch parts[3] {
            case "start": return "workload.start"
            case "stop": return "workload.stop"
            case "update": return "workload.update"
            case "delete": return "workload.delete"
            case "events": return "workload.events"
            default: return nil
            }
        }
    }

    enum PublicHTTP {
        static func bind(port: Int) throws -> (fd: Int32, port: Int) {
            let fd = socket(AF_INET, PlatformSocket.stream, 0)
            guard fd >= 0 else { throw LocalManagementError.unavailable }
            var reuse: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    PublicSocket.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 16) == 0 else {
                close(fd)
                throw LocalManagementError.unavailable
            }
            var got = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &got) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    getsockname(fd, sock, &length)
                }
            }
            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            return (fd, Int(UInt16(bigEndian: got.sin_port)))
        }

        static func accept(_ fd: Int32) -> Int32 {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waited = poll(&pollFD, 1, 200)
            if waited <= 0 { return -1 }
            return PublicSocket.accept(fd)
        }

        static func readRequest(_ fd: Int32) -> PublicHTTPRequest? {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            guard let first = lines.first else { return nil }
            let bits = first.split(separator: " ")
            guard bits.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() where line.contains(":") {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return PublicHTTPRequest(
                method: String(bits[0]),
                path: String(bits[1]),
                session: headers["x-bark-session"],
                claim: headers["x-bark-user"],
                operationID: headers["x-bark-operation"],
                upgradeWebSocket: headers["upgrade"]?.lowercased() == "websocket",
            )
        }

        static func write(_ fd: Int32, _ text: String) {
            var remaining = Data(text.utf8)
            while !remaining.isEmpty {
                let wrote = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return PublicSocket.write(fd, base, raw.count)
                }
                if wrote <= 0 { return }
                remaining.removeFirst(wrote)
            }
        }

        static func json(status: Int, body: String) -> String {
            """
            HTTP/1.1 \(status) \(status == 200 ? "OK" : "Forbidden")\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        }

        static func websocket(_ body: String) -> String {
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            \r
            \(body)
            """
        }
    }

    private enum PublicSocket {
        static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
            #if canImport(Darwin)
                Darwin.bind(fd, addr, len)
            #else
                Glibc.bind(fd, addr, len)
            #endif
        }

        static func accept(_ fd: Int32) -> Int32 {
            #if canImport(Darwin)
                Darwin.accept(fd, nil, nil)
            #else
                Glibc.accept(fd, nil, nil)
            #endif
        }

        static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
            #if canImport(Darwin)
                Darwin.write(fd, buffer, count)
            #else
                Glibc.write(fd, buffer, count)
            #endif
        }
    }

    enum PublicTLS {
        static func material() throws -> (context: NIOSSLContext, certificatePEM: String) {
            let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
            let name = try DistinguishedName { CommonName("BarkServer") }
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(1),
                publicKey: key.publicKey,
                notValidBefore: Date().addingTimeInterval(-60),
                notValidAfter: Date().addingTimeInterval(86_400),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    KeyUsage(digitalSignature: true)
                },
                issuerPrivateKey: key,
            )
            let certPEM = try certificate.serializeAsPEM().pemString
            let keyPEM = try key.serializeAsPEM().pemString
            let nioCert = try NIOSSLCertificate(bytes: Array(certPEM.utf8), format: .pem)
            let nioKey = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
            let tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(nioCert)],
                privateKey: .privateKey(nioKey),
            )
            let context = try NIOSSLContext(configuration: tls)
            return (context, certPEM)
        }
    }

    private final class PublicTLSBanner: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelActive(context: ChannelHandlerContext) {
            var buffer = context.channel.allocator.buffer(capacity: 16)
            buffer.writeString("barkvisor-device")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
#endif
