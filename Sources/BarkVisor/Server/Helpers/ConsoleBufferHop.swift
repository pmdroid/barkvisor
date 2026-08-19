import BarkVisorCore
import Foundation
import NIOCore
import NIOPosix

/// Far end for a serial console client (PAS-233).
///
/// The manager already holds the QEMU unix socket. Opening this end
/// replays scrollback, then registers one subscriber. Overflow, bind-closes,
/// and inbound-closed-before-dial stay in `WebSocketHop`.
struct ConsoleBufferHopFarEnd: WebSocketHopFarEnding {
    let buffers: ConsoleBufferManager
    let vmID: String

    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        let peer = ConsoleBufferHopPeer(buffers: buffers, vmID: vmID)
        configure(peer)
        if peer.isClosed {
            return peer
        }
        let scrollback = await buffers.scrollback(vmID: vmID)
        if !scrollback.isEmpty {
            peer.receive(bytes: Array(scrollback))
        }
        if peer.isClosed {
            return peer
        }
        await peer.subscribe()
        return peer
    }
}

final class ConsoleBufferHopPeer: WebSocketHopPeer, @unchecked Sendable {
    private let buffers: ConsoleBufferManager
    private let vmID: String
    private let listenerID = UUID().uuidString
    private let lock = NSLock()
    private var box: WebSocketPipeBox?
    private var closed = false
    private var subscribed = false
    private let closePromise: EventLoopPromise<Void>

    init(
        buffers: ConsoleBufferManager,
        vmID: String,
        eventLoop: any EventLoop = WebSocketHop.dialEventLoopGroup.next(),
    ) {
        self.buffers = buffers
        self.vmID = vmID
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

    func send(_ frame: WebSocketPipeBox.Frame, completed: (@Sendable () -> Void)?) {
        let closed: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return self.closed
        }()
        guard !closed else {
            completed?()
            return
        }
        let data = switch frame {
        case let .binary(buffer): Data(buffer.readableBytesView)
        case let .text(text): Data(text.utf8)
        }
        let buffers = buffers
        let vmID = vmID
        Task {
            await buffers.write(vmID: vmID, data: data)
            completed?()
        }
    }

    func receive(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        receive(buffer)
    }

    func receive(_ buffer: ByteBuffer) {
        let box: WebSocketPipeBox? = {
            lock.lock()
            defer { lock.unlock() }
            if closed { return nil }
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

    func subscribe() async {
        let shouldSubscribe: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if closed || subscribed { return false }
            subscribed = true
            return true
        }()
        guard shouldSubscribe else { return }
        await buffers.addListener(
            vmID: vmID,
            id: listenerID,
            callback: { [weak self] bytes in
                self?.receive(bytes: bytes)
            },
            onClose: { [weak self] in
                self?.close()
            },
        )
        if isClosed {
            await buffers.removeListener(vmID: vmID, id: listenerID)
        }
    }

    func close() {
        let shouldDrop: Bool = {
            lock.lock()
            let already = closed
            closed = true
            let subscribed = self.subscribed
            lock.unlock()
            if !already {
                closePromise.succeed(())
            }
            return !already && subscribed
        }()
        guard shouldDrop else { return }
        let buffers = buffers
        let vmID = vmID
        let listenerID = listenerID
        Task {
            await buffers.removeListener(vmID: vmID, id: listenerID)
        }
    }
}
