import BarkVisorCore
import Foundation
import NIOCore
import NIOPosix

/// Far end for an app-workload terminal client (issue #609).
///
/// One `DockerExecSession` (`docker exec -it <container> <shell>` on a PTY)
/// per WebSocket. Binary frames are raw terminal bytes both directions; text
/// frames carry JSON control messages — currently `{"type":"resize","cols":…,
/// "rows":…}` → `TIOCSWINSZ`. Child exit closes the peer (which tears the hop
/// down both ways); peer close kills + reaps the child.
struct DockerExecHopFarEnd: WebSocketHopFarEnding {
    let session: DockerExecSession
    let request: DockerExecRequest

    func open(
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        let peer = DockerExecHopPeer(session: session)
        configure(peer)
        if peer.isClosed {
            // Client vanished before we spawned; nothing to exec.
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

/// Terminal control frames from the browser (text JSON), per issue #609.
enum DockerExecControl {
    struct Resize: Equatable {
        var cols: Int
        var rows: Int
    }

    /// `nil` = not a (valid) resize control frame. Unknown types are ignored,
    /// not fatal — future frames must not break old daemons.
    static func decodeResize(_ text: String) -> Resize? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String)?.caseInsensitiveCompare("resize") == .orderedSame
        else { return nil }
        let cols = intValue(object["cols"]), rows = intValue(object["rows"])
        guard cols != nil || rows != nil else { return nil }
        return Resize(cols: max(1, cols ?? 80), rows: max(1, rows ?? 24))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}

final class DockerExecHopPeer: WebSocketHopPeer, @unchecked Sendable {
    private let session: DockerExecSession
    private let lock = NSLock()
    private var box: WebSocketPipeBox?
    private var closed = false
    private let closePromise: EventLoopPromise<Void>

    init(
        session: DockerExecSession,
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

    /// Client → exec: text = control JSON (resize), binary = stdin bytes.
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
            // Unknown text frames are ignored (forward-compatible control).
        }
        completed?()
    }

    func receive(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        receive(buffer)
    }

    /// Exec → client: chunk into capped binary frames like the unix/serial peers.
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
            session.terminate()
        }
    }
}
