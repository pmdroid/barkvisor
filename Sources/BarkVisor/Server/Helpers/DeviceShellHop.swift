#if !os(Windows)
    import BarkVisorCore
    import Foundation
    import NIOCore
    import NIOPosix

    struct DeviceShellHopFarEnd: WebSocketHopFarEnding {
        let session: DeviceShellSession
        let request: DeviceShellRequest

        func open(
            configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
        ) async throws -> any WebSocketHopPeer {
            let peer = DeviceShellHopPeer(session: session)
            configure(peer)
            if peer.isClosed {
                session.terminate()
                peer.close()
                return peer
            }
            do {
                try session.start(
                    request,
                    onData: { [weak peer] bytes in
                        peer?.receive(bytes: bytes)
                    },
                    onExit: { [weak peer] _ in
                        peer?.close()
                    },
                )
            } catch {
                peer.close()
                throw error
            }
            return peer
        }
    }

    final class DeviceShellHopPeer: WebSocketHopPeer, @unchecked Sendable {
        private let session: DeviceShellSession
        private let lock = NSLock()
        private var box: WebSocketPipeBox?
        private var closed = false
        private let closePromise: EventLoopPromise<Void>

        init(
            session: DeviceShellSession,
            eventLoop: any EventLoop = WebSocketHop.dialEventLoopGroup.next(),
        ) {
            self.session = session
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
            switch frame {
            case let .binary(buffer):
                var remaining = buffer
                while remaining.readableBytes > 0 {
                    guard let bytes = remaining.readBytes(length: remaining.readableBytes) else { break }
                    session.write(Array(bytes))
                }
            case let .text(text):
                if let resize = DockerExecControl.decodeResize(text) {
                    session.resize(cols: resize.cols, rows: resize.rows)
                }
            }
            completed?()
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

        func close() {
            let already: Bool = {
                lock.lock()
                let was = closed
                closed = true
                lock.unlock()
                if !was { closePromise.succeed(()) }
                return was
            }()
            if !already {
                session.requestShellExit()
                session.terminate()
            }
        }
    }
#endif
