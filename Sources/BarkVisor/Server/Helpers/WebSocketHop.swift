import BarkVisorCore
import Foundation
import NIOCore
import NIOPosix
import Vapor

/// Client WebSocket ↔ far-end stream (PAS-224).
///
/// Controllers only pick a target and a dialer. This module owns the
/// pre-attach buffer, 256 KiB cap, overflow-close, bind-closes, and
/// the inbound-closed-before-dial race. WebSocket dials always use
/// `MultiThreadedEventLoopGroup.singleton`, never the inbound loop.
enum WebSocketHop {
    /// websocket-kit clients default to 16 KiB frames. A Tight framebuffer
    /// read grows past that and the Home hop (NIO client) closes mid-picture.
    static let maxBinaryFrameBytes = 12_288

    static var dialEventLoopGroup: EventLoopGroup {
        MultiThreadedEventLoopGroup.singleton
    }

    static func run(
        inbound: WebSocket,
        url: URL,
        dialer: any HomeWebSocketDialing,
        maxPendingBytes: Int = WebSocketPipeBox.defaultMaxPendingBytes,
    ) async {
        await run(
            inbound: VaporWebSocketPeer(inbound),
            url: url,
            dialer: dialer,
            maxPendingBytes: maxPendingBytes,
        )
    }

    static func run(
        inbound: any WebSocketHopPeer,
        url: URL,
        dialer: any HomeWebSocketDialing,
        maxPendingBytes: Int = WebSocketPipeBox.defaultMaxPendingBytes,
    ) async {
        await run(
            inbound: inbound,
            farEnd: HomeWebSocketHopFarEnd(url: url, dialer: dialer),
            maxPendingBytes: maxPendingBytes,
            logTarget: safeHopTarget(url),
        )
    }

    static func run(
        inbound: WebSocket,
        unixSocketPath: String,
        maxPendingBytes: Int = WebSocketPipeBox.defaultMaxPendingBytes,
    ) async {
        await run(
            inbound: VaporWebSocketPeer(inbound),
            unixSocketPath: unixSocketPath,
            maxPendingBytes: maxPendingBytes,
        )
    }

    static func run(
        inbound: any WebSocketHopPeer,
        unixSocketPath: String,
        maxPendingBytes: Int = WebSocketPipeBox.defaultMaxPendingBytes,
    ) async {
        await run(
            inbound: inbound,
            farEnd: UnixSocketHopFarEnd(path: unixSocketPath),
            maxPendingBytes: maxPendingBytes,
            logTarget: "unix:\(unixSocketPath)",
        )
    }

    static func run(
        inbound: any WebSocketHopPeer,
        farEnd: any WebSocketHopFarEnding,
        maxPendingBytes: Int = WebSocketPipeBox.defaultMaxPendingBytes,
        logTarget: String? = nil,
    ) async {
        let toRemote = WebSocketPipeBox()
        toRemote.maxPendingBytes = maxPendingBytes
        let toClient = WebSocketPipeBox()
        toClient.maxPendingBytes = maxPendingBytes
        toRemote.onOverflow = { logOverflow(logTarget) }
        toClient.onOverflow = { logOverflow(logTarget) }
        let lifetime = HopLifetime()

        inbound.capture(into: toRemote)
        inbound.closeFuture.whenComplete { _ in
            lifetime.cancel()
        }
        if inbound.isClosed {
            lifetime.cancel()
            return
        }

        do {
            let remote = try await farEnd.open { peer in
                if lifetime.accept(peer) {
                    peer.capture(into: toClient)
                } else {
                    peer.close()
                }
            }
            if inbound.isClosed || remote.isClosed || toRemote.overflowed || toClient.overflowed {
                if toRemote.overflowed || toClient.overflowed {
                    logOverflow(logTarget)
                }
                inbound.close()
                remote.close()
                return
            }
            toRemote.attach(remote)
            toClient.attach(inbound)
            bindCloses(local: inbound, remote: remote)
            if toRemote.overflowed || toClient.overflowed {
                logOverflow(logTarget)
                inbound.close()
                remote.close()
            }
        } catch {
            let whereTo = logTarget.map { " (\($0))" } ?? ""
            Log.server.error("Console hop failed\(whereTo): \(error.localizedDescription)")
            inbound.close()
        }
    }

    private static func logOverflow(_ logTarget: String?) {
        let whereTo = logTarget.map { " (\($0))" } ?? ""
        Log.server.error("Console hop overflow\(whereTo): pending frames exceeded the pipe cap")
    }

    /// Scheme/host/port/path only — tickets and sessions stay off the log line.
    static func safeHopTarget(_ url: URL) -> String {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        parts.path = url.path
        return parts.string ?? url.path
    }

    static func bindCloses(local: any WebSocketHopPeer, remote: any WebSocketHopPeer) {
        local.closeFuture.whenComplete { _ in
            remote.close()
        }
        remote.closeFuture.whenComplete { _ in
            local.close()
        }
    }
}

/// One side of a hop: a Vapor WebSocket, a unix-socket channel, or a test fake.
protocol WebSocketHopPeer: Sendable {
    var isClosed: Bool { get }
    var closeFuture: EventLoopFuture<Void> { get }
    func send(_ frame: WebSocketPipeBox.Frame, completed: (@Sendable () -> Void)?)
    func capture(into box: WebSocketPipeBox)
    func close()
}

protocol WebSocketHopFarEnding: Sendable {
    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer
}

struct VaporWebSocketPeer: WebSocketHopPeer {
    let ws: WebSocket

    init(_ ws: WebSocket) {
        self.ws = ws
    }

    var isClosed: Bool {
        ws.isClosed
    }
    var closeFuture: EventLoopFuture<Void> {
        ws.onClose
    }

    func send(_ frame: WebSocketPipeBox.Frame, completed: (@Sendable () -> Void)?) {
        WebSocketRelay.send(frame, on: ws, completed: completed)
    }

    func capture(into box: WebSocketPipeBox) {
        WebSocketRelay.onEventLoop(ws) {
            WebSocketRelay.capture(from: ws, into: box)
        }
    }

    func close() {
        WebSocketRelay.close(ws)
    }
}

struct HomeWebSocketHopFarEnd: WebSocketHopFarEnding {
    let url: URL
    let dialer: any HomeWebSocketDialing

    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        try await dialer.connect(
            url: url,
            on: WebSocketHop.dialEventLoopGroup,
            configure: configure,
        )
    }
}

struct UnixSocketHopFarEnd: WebSocketHopFarEnding {
    let path: String
    var group: EventLoopGroup = WebSocketHop.dialEventLoopGroup

    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        let peer = UnixSocketHopPeer()
        configure(peer)
        let channel = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Channel, Error>) in
            let once = OnceResume(cont)
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(UnixSocketToPipeHandler(peer: peer))
                }
                .connect(unixDomainSocketPath: path)
                .whenComplete { result in
                    _ = once.resume(result)
                }
        }
        peer.activate(channel)
        return peer
    }
}

struct PlainWebSocketDialer: HomeWebSocketDialing {
    func connect(
        url: URL,
        on eventLoopGroup: EventLoopGroup,
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        let ws = try await HomeWebSocketDialer.open(
            url: url,
            on: eventLoopGroup,
            configure: { ws in configure(VaporWebSocketPeer(ws)) },
        )
        return VaporWebSocketPeer(ws)
    }
}

/// Closes a late far end if the inbound socket already died.
private final class HopLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var open: (any WebSocketHopPeer)?

    func accept(_ peer: any WebSocketHopPeer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        open = peer
        return true
    }

    func cancel() {
        let extra: (any WebSocketHopPeer)?
        lock.lock()
        cancelled = true
        extra = open
        open = nil
        lock.unlock()
        extra?.close()
    }
}

final class UnixSocketHopPeer: WebSocketHopPeer, @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var box: WebSocketPipeBox?
    private var closed = false
    private let closePromise: EventLoopPromise<Void>

    init(eventLoop: any EventLoop = WebSocketHop.dialEventLoopGroup.next()) {
        closePromise = eventLoop.makePromise(of: Void.self)
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var closeFuture: EventLoopFuture<Void> {
        closePromise.futureResult
    }

    func capture(into box: WebSocketPipeBox) {
        lock.lock()
        self.box = box
        lock.unlock()
    }

    func activate(_ channel: Channel) {
        let alreadyClosed: Bool = {
            lock.lock()
            defer { lock.unlock() }
            self.channel = channel
            return closed
        }()
        channel.closeFuture.whenComplete { [self] _ in
            markClosed()
        }
        if alreadyClosed {
            channel.close(promise: nil)
        }
    }

    func receive(_ buffer: ByteBuffer) {
        let box: WebSocketPipeBox? = {
            lock.lock()
            defer { lock.unlock() }
            return self.box
        }()
        guard let box else { return }
        var remaining = buffer
        while remaining.readableBytes > 0 {
            let n = min(remaining.readableBytes, WebSocketHop.maxBinaryFrameBytes)
            guard var slice = remaining.readSlice(length: n) else { break }
            var owned = ByteBufferAllocator().buffer(capacity: n)
            owned.writeBuffer(&slice)
            if !box.sendOrBuffer(.binary(owned)) {
                close()
                return
            }
        }
    }

    func send(_ frame: WebSocketPipeBox.Frame, completed: (@Sendable () -> Void)?) {
        let channel: Channel? = {
            lock.lock()
            defer { lock.unlock() }
            return self.channel
        }()
        guard let channel else {
            completed?()
            return
        }
        channel.eventLoop.execute {
            guard channel.isActive else {
                completed?()
                return
            }
            let promise = channel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { _ in
                completed?()
            }
            switch frame {
            case let .binary(buffer):
                channel.writeAndFlush(buffer, promise: promise)
            case let .text(text):
                var buffer = channel.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                channel.writeAndFlush(buffer, promise: promise)
            }
        }
    }

    func close() {
        let channel: Channel? = {
            lock.lock()
            let already = closed
            closed = true
            let channel = self.channel
            lock.unlock()
            if !already {
                closePromise.succeed(())
            }
            return already ? nil : channel
        }()
        channel?.close(promise: nil)
    }

    private func markClosed() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        if !already {
            closePromise.succeed(())
        }
    }
}

private final class UnixSocketToPipeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let peer: UnixSocketHopPeer

    init(peer: UnixSocketHopPeer) {
        self.peer = peer
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        peer.receive(unwrapInboundIn(data))
    }

    func channelInactive(context _: ChannelHandlerContext) {
        peer.close()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
        peer.close()
    }
}
