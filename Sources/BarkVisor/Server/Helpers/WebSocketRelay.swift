import BarkVisorCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Vapor

/// Bidirectional pipe for Home / agent / local VNC hops (PAS-200, PAS-224).
///
/// Inbound frames are buffered until the outbound peer is attached so a
/// client that sends immediately after 101 is not dropped.
final class WebSocketPipeBox: @unchecked Sendable {
    enum Frame {
        case binary(ByteBuffer)
        case text(String)
    }

    static let defaultMaxPendingBytes = 262_144

    private let lock = NSLock()
    private var remote: (any WebSocketHopPeer)?
    private var pending: [Frame] = []
    private var pendingBytes = 0
    var maxPendingBytes = WebSocketPipeBox.defaultMaxPendingBytes
    private(set) var overflowed = false

    func attach(_ peer: any WebSocketHopPeer) {
        while true {
            let batch: [Frame] = {
                lock.lock()
                defer { lock.unlock() }
                let frames = pending
                pending.removeAll()
                if frames.isEmpty {
                    remote = peer
                }
                return frames
            }()
            guard !batch.isEmpty else { return }
            for frame in batch {
                sendLive(frame, on: peer)
            }
        }
    }

    func sendOrBuffer(_ frame: Frame) -> Bool {
        let outcome: ((any WebSocketHopPeer)?, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            if overflowed { return (nil, false) }
            if let remote {
                return (remote, true)
            }
            let size = Self.byteCount(frame)
            if pendingBytes + size > maxPendingBytes {
                overflowed = true
                pending.removeAll()
                pendingBytes = 0
                return (nil, false)
            }
            pending.append(frame)
            pendingBytes += size
            return (nil, true)
        }()
        if let peer = outcome.0 {
            return sendLive(frame, on: peer)
        }
        return outcome.1
    }

    /// Reserve against the same cap after attach; release when the write completes.
    @discardableResult
    private func sendLive(_ frame: Frame, on peer: any WebSocketHopPeer) -> Bool {
        let size = Self.byteCount(frame)
        let reserved: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if overflowed { return false }
            if remote != nil, pendingBytes + size > maxPendingBytes {
                overflowed = true
                return false
            }
            if remote != nil {
                pendingBytes += size
            }
            return true
        }()
        guard reserved else { return false }
        peer.send(frame) { [self] in
            lock.lock()
            pendingBytes = max(0, pendingBytes - size)
            lock.unlock()
        }
        return true
    }

    private static func byteCount(_ frame: Frame) -> Int {
        switch frame {
        case let .binary(buffer): buffer.readableBytes
        case let .text(text): text.utf8.count
        }
    }
}

enum WebSocketRelay {
    static func pipe(local: WebSocket, remote: WebSocket) {
        bindCloses(local: local, remote: remote)
    }

    /// Install receive handlers. Call this inside `WebSocket.connect` so
    /// server-first frames (RFB banner, serial scrollback) are not dropped.
    static func capture(from ws: WebSocket, into box: WebSocketPipeBox) {
        ws.onBinary { inbound, buffer in
            if !box.sendOrBuffer(.binary(buffer)) {
                close(inbound)
            }
        }
        ws.onText { inbound, text in
            if !box.sendOrBuffer(.text(text)) {
                close(inbound)
            }
        }
    }

    static func bindCloses(local: WebSocket, remote: WebSocket) {
        local.onClose.whenComplete { _ in
            close(remote)
        }
        remote.onClose.whenComplete { _ in
            close(local)
        }
    }

    static func send(
        _ frame: WebSocketPipeBox.Frame,
        on ws: WebSocket,
        completed: (@Sendable () -> Void)? = nil,
    ) {
        onEventLoop(ws) {
            guard !ws.isClosed else {
                completed?()
                return
            }
            let promise = ws.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { _ in
                completed?()
            }
            switch frame {
            case let .binary(buffer):
                ws.send(raw: buffer.readableBytesView, opcode: .binary, fin: true, promise: promise)
            case let .text(text):
                ws.send(text, promise: promise)
            }
        }
    }

    static func close(_ ws: WebSocket) {
        onEventLoop(ws) {
            if !ws.isClosed {
                ws.close(promise: nil)
            }
        }
    }

    static func onEventLoop(_ ws: WebSocket, _ body: @escaping @Sendable () -> Void) {
        if ws.eventLoop.inEventLoop {
            body()
        } else {
            ws.eventLoop.execute(body)
        }
    }
}

final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        continuation.resume(with: result)
        return true
    }
}

/// Closes a late handshake if the 10s dial already failed.
private final class DialLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var open: WebSocket?

    func accept(_ ws: WebSocket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        open = ws
        return true
    }

    func cancel() {
        let extra: WebSocket?
        lock.lock()
        cancelled = true
        extra = open
        open = nil
        lock.unlock()
        if let extra {
            WebSocketRelay.close(extra)
        }
    }
}

protocol HomeWebSocketDialing: Sendable {
    func connect(
        url: URL,
        on eventLoopGroup: EventLoopGroup,
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer
}

/// Outbound WebSocket client. `ws://` is loopback (This Device / agent hop).
/// `wss://` uses the same mTLS material as the Home HTTP proxy.
struct HomeWebSocketDialer: HomeWebSocketDialing {
    var dataDir: URL
    var hostId: String

    static let dialTimeoutNanoseconds: UInt64 = 10_000_000_000

    func connect(
        url: URL,
        on eventLoopGroup: EventLoopGroup,
        configure: @escaping @Sendable (any WebSocketHopPeer) -> Void,
    ) async throws -> any WebSocketHopPeer {
        var configuration = WebSocketClient.Configuration()
        if url.scheme?.lowercased() == "wss" {
            configuration.tlsConfiguration = try Self.mtlsConfiguration(
                dataDir: dataDir,
                hostId: hostId,
            )
        }
        let ws = try await Self.open(
            url: url,
            configuration: configuration,
            on: eventLoopGroup,
            configure: { ws in configure(VaporWebSocketPeer(ws)) },
        )
        return VaporWebSocketPeer(ws)
    }

    static func open(
        url: URL,
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        configure: @escaping @Sendable (WebSocket) -> Void = { _ in },
    ) async throws -> WebSocket {
        let lifetime = DialLifetime()
        do {
            return try await withThrowingTaskGroup(of: WebSocket.self) { group in
                group.addTask {
                    try await connectOnce(
                        url: url,
                        configuration: configuration,
                        on: eventLoopGroup,
                        lifetime: lifetime,
                        configure: configure,
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: dialTimeoutNanoseconds)
                    throw Abort(.gatewayTimeout, reason: "Device console did not answer")
                }
                let socket = try await group.next()!
                group.cancelAll()
                return socket
            }
        } catch {
            lifetime.cancel()
            throw error
        }
    }

    private static func connectOnce(
        url: URL,
        configuration: WebSocketClient.Configuration,
        on eventLoopGroup: EventLoopGroup,
        lifetime: DialLifetime,
        configure: @escaping @Sendable (WebSocket) -> Void,
    ) async throws -> WebSocket {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebSocket, Error>) in
            let once = OnceResume(cont)
            let future = WebSocket.connect(
                to: url.absoluteString,
                configuration: configuration,
                on: eventLoopGroup,
            ) { ws in
                if lifetime.accept(ws) {
                    configure(ws)
                    _ = once.resume(.success(ws))
                } else {
                    WebSocketRelay.close(ws)
                    _ = once.resume(.failure(CancellationError()))
                }
            }
            future.whenFailure { error in
                _ = once.resume(.failure(error))
            }
        }
    }

    static func mtlsConfiguration(dataDir: URL, hostId: String) throws -> TLSConfiguration {
        let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
        let receipt = try? PairingService.loadReceipt(dataDir: dataDir)
        let presented = AgentPlaneCertificates.presentationCertificatePEM(
            material: material,
            receipt: receipt,
        )
        let trusts = AgentPlaneCertificates.trustCertificatePEMs(
            material: material,
            receipt: receipt,
        )
        let roots = try trusts.map { pem in
            try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
        }
        let cert = try NIOSSLCertificate(bytes: Array(presented.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(material.deviceKeyPEM.utf8), format: .pem)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .noHostnameVerification
        tls.trustRoots = .certificates(roots)
        tls.certificateChain = [.certificate(cert)]
        tls.privateKey = .privateKey(key)
        tls.minimumTLSVersion = .tlsv12
        return tls
    }
}
