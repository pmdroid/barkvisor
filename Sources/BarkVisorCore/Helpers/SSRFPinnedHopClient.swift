#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS

/// One POSIX hop client for a Library fetch. TCP uses the current pin IP; Host and
/// TLS SNI stay on `originalHost`. Re-pinning does not create or shut down a client.
final class SSRFPinnedHopClient: @unchecked Sendable {
    let timeout: TimeInterval
    private var didShutdown = false
    private var sslContext: NIOSSLContext?

    init(timeout: TimeInterval) {
        self.timeout = timeout
        SSRFPinnedURLProtocol.recordClientCreated()
    }

    func prepare(for pin: PinnedEndpoint) throws {
        if didShutdown {
            throw URLError(.cancelled)
        }
        SSRFPinnedURLProtocol.recordDNSOverride([pin.originalHost: pin.connectIP])
    }

    func execute(
        request: URLRequest,
        url: URL,
        pin: PinnedEndpoint,
    ) async throws -> (HTTPResponseHead, AsyncThrowingStream<ByteBuffer, Error>) {
        if didShutdown {
            throw URLError(.cancelled)
        }
        let address = try SocketAddress(ipAddress: pin.connectIP, port: pin.port)
        let head = hopRequestHead(request: request, url: url, pin: pin)
        let body = request.httpBody
        let timeout = self.timeout
        let usesTLS = pin.usesTLS
        let sni = Self.sniName(pin.originalHost)
        let sslContext: NIOSSLContext?
        if usesTLS {
            if let existing = self.sslContext {
                sslContext = existing
            } else {
                let created = try NIOSSLContext(configuration: .makeClientConfiguration())
                self.sslContext = created
                sslContext = created
            }
        } else {
            sslContext = nil
        }

        // Attach the body consumer before connect. A localhost 200 often delivers
        // head+body+end on one event-loop tick; creating the stream after waitHead
        // lets Linux drop those buffered bytes (empty URLSession data, HTTP 200).
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream(
            bufferingPolicy: .unbounded,
        )
        let box = SSRFHopExchange()
        box.startBody(continuation)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.eventLoop.submit {
                    let sync = channel.pipeline.syncOperations
                    if usesTLS, let sslContext {
                        try sync.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: sni))
                    }
                    try sync.addHTTPClientHandlers()
                    try sync.addHandler(
                        SSRFHopHandler(
                            head: head, body: body, usesTLS: usesTLS, timeout: timeout, exchange: box,
                        ),
                    )
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(to: address).get()
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
        continuation.onTermination = { @Sendable _ in
            channel.close(mode: .all, promise: nil)
        }
        let responseHead = try await box.waitHead()
        return (responseHead, stream)
    }

    func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        SSRFPinnedURLProtocol.finishShutdown(succeeded: true)
    }

    private func hopRequestHead(request: URLRequest, url: URL, pin: PinnedEndpoint) -> HTTPRequestHead {
        var uri = url.path
        if uri.isEmpty { uri = "/" }
        if let query = url.query, !query.isEmpty {
            uri += "?\(query)"
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Host", value: Self.hostHeader(pin))
        headers.replaceOrAdd(name: "Connection", value: "close")
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            if name.caseInsensitiveCompare("Host") == .orderedSame { continue }
            if name.caseInsensitiveCompare(SSRFPinnedURLProtocol.timeoutHeader) == .orderedSame { continue }
            headers.replaceOrAdd(name: name, value: value)
        }
        if let body = request.httpBody {
            headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        }
        return HTTPRequestHead(
            version: .http1_1,
            method: HTTPMethod(rawValue: request.httpMethod ?? "GET"),
            uri: uri,
            headers: headers,
        )
    }

    private static func hostHeader(_ pin: PinnedEndpoint) -> String {
        let defaultPort = pin.usesTLS ? 443 : 80
        let host = pin.originalHost.contains(":") ? "[\(pin.originalHost)]" : pin.originalHost
        if pin.port == defaultPort { return host }
        return "\(host):\(pin.port)"
    }

    private static func sniName(_ host: String) -> String? {
        (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
    }
}

private final class SSRFHopExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var head: Result<HTTPResponseHead, Error>?
    private var headWaiter: CheckedContinuation<HTTPResponseHead, Error>?
    private var body: AsyncThrowingStream<ByteBuffer, Error>.Continuation?
    private var pendingBody: [ByteBuffer] = []
    private var bodyEnd: Result<Void, Error>?

    func waitHead() async throws -> HTTPResponseHead {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let head {
                lock.unlock()
                continuation.resume(with: head)
            } else {
                headWaiter = continuation
                lock.unlock()
            }
        }
    }

    func startBody(_ continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation) {
        lock.lock()
        body = continuation
        let pending = pendingBody
        pendingBody = []
        let end = bodyEnd
        lock.unlock()
        for buffer in pending {
            continuation.yield(buffer)
        }
        if let end {
            switch end {
            case .success:
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }

    func receiveHead(_ head: HTTPResponseHead) {
        resumeHead(.success(head))
    }

    func receiveBody(_ buffer: ByteBuffer) {
        lock.lock()
        if let body {
            lock.unlock()
            body.yield(buffer)
        } else {
            pendingBody.append(buffer)
            lock.unlock()
        }
    }

    func receiveEnd() {
        finishBody(.success(()))
    }

    func fail(_ error: Error) {
        resumeHead(.failure(error))
        finishBody(.failure(error))
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bodyEnd != nil && head != nil
    }

    private func resumeHead(_ result: Result<HTTPResponseHead, Error>) {
        lock.lock()
        if head != nil {
            lock.unlock()
            return
        }
        head = result
        let waiter = headWaiter
        headWaiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func finishBody(_ result: Result<Void, Error>) {
        lock.lock()
        if bodyEnd != nil {
            lock.unlock()
            return
        }
        bodyEnd = result
        let body = self.body
        lock.unlock()
        guard let body else { return }
        switch result {
        case .success:
            body.finish()
        case let .failure(error):
            body.finish(throwing: error)
        }
    }
}

private final class SSRFHopHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let head: HTTPRequestHead
    private let body: Data?
    private let usesTLS: Bool
    private let timeout: TimeInterval
    private let exchange: SSRFHopExchange
    private var sent = false
    private var timeoutTask: Scheduled<Void>?

    init(
        head: HTTPRequestHead,
        body: Data?,
        usesTLS: Bool,
        timeout: TimeInterval,
        exchange: SSRFHopExchange,
    ) {
        self.head = head
        self.body = body
        self.usesTLS = usesTLS
        self.timeout = timeout
        self.exchange = exchange
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let seconds = max(1, Int64(timeout.rounded(.up)))
        timeoutTask = context.eventLoop.scheduleTask(in: .seconds(seconds)) {
            self.exchange.fail(URLError(.timedOut))
            context.close(promise: nil)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        if !usesTLS {
            sendRequest(context)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            sendRequest(context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(responseHead):
            exchange.receiveHead(responseHead)
        case let .body(buffer):
            exchange.receiveBody(buffer)
        case .end:
            timeoutTask?.cancel()
            exchange.receiveEnd()
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        timeoutTask?.cancel()
        exchange.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        timeoutTask?.cancel()
        if !exchange.isFinished {
            exchange.fail(URLError(.networkConnectionLost))
        }
        context.fireChannelInactive()
    }

    private func sendRequest(_ context: ChannelHandlerContext) {
        guard !sent else { return }
        sent = true
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
